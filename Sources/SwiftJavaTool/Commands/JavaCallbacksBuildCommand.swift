//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2024 Apple Inc. and the Swift.org project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift.org project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import ArgumentParser
import Foundation
import Subprocess
import SwiftJavaConfigurationShared

#if canImport(System)
import System
#else
@preconcurrency import SystemPackage
#endif

extension SwiftJava {
  /// Builds Swift-Java callbacks in a single command:
  /// 1. Building SwiftKitCore with Gradle
  /// 2. Compiling extracted Java sources with javac
  /// 3. Running `swift-java configure` to produce a swift-java.config
  /// 4. Running `swift-java wrap-java` to generate Swift wrappers
  ///
  /// **WORKAROUND**: rdar://172649681 if we invoke commands one by one with java outputs SwiftPM will link Foundation
  ///
  /// This command is used by ``JExtractSwiftPlugin`` to consolidate all of the above
  /// into a single build command that declares only a Swift file as its output,
  /// avoiding SPM treating intermediate Java artifacts (compiled classes, config files,
  /// Gradle output directories) as module resources, which would trigger
  /// resource_bundle_accessor.swift generation and pull Foundation.Bundle into the binary.
  struct JavaCallbacksBuildCommand: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
      commandName: "java-callbacks-build",
      abstract:
        "Build SwiftKitCore, compile Java callbacks, and generate Swift wrappers (for use by JExtractSwiftPlugin)",
      shouldDisplay: false,
    )

    // MARK: Gradle options

    @Option(help: "Path to the gradle (or gradlew) executable")
    var gradleExecutable: String

    @Option(help: "The Gradle project directory (passed as --project-dir)")
    var gradleProjectDir: String

    @Option(help: "The Gradle user home directory (GRADLE_USER_HOME)")
    var gradleUserHome: String

    // MARK: javac options

    @Option(help: "Path to the javac executable")
    var javac: String

    @Option(help: "Path to the @-file listing Java sources to compile")
    var javaSourcesList: String

    @Option(help: "Directory where compiled Java classes should be output")
    var javaOutputDirectory: String

    @Option(help: "Path to SwiftKitCore compiled classes (classpath for javac and wrap-java)")
    var swiftKitCoreClasspath: String

    // MARK: Swift generation options

    @Option(help: "The name of the Swift module")
    var swiftModule: String

    @Option(help: "Prefix to add to generated Swift type names")
    var swiftTypePrefix: String?

    @Option(
      name: .customLong("output-directory"),
      help: "Directory where generated Swift files should be written",
    )
    var outputDirectory: String

    @Option(help: "Name of the single Swift output file")
    var singleSwiftFileOutput: String

    @Option(help: "Path to the swift-java tool executable (used to invoke subcommands)")
    var swiftJavaTool: String

    @Option(
      help:
        "Path to the source module's swift-java.config. Forwarded to the nested `configure` step so it loads the correct initial configuration regardless of the SwiftPM target's on-disk layout (e.g. a custom `path:` / package-in-package). When omitted, `configure` falls back to its `./Sources/<module>` convention."
    )
    var swiftJavaConfig: String?

    @Option(
      help:
        "Dependency module configurations (format: ModuleName=/path/to/swift-java.config)"
    )
    var dependsOn: [String] = []

    mutating func run() async throws {
      let outputDir = URL(fileURLWithPath: outputDirectory)
      let outputFile = outputDir.appendingPathComponent(singleSwiftFileOutput)

      // 1. Compile SwiftKitCore using Gradle if the classpath is not already
      // present. Multiple callback-enabled modules in the same SwiftPM build
      // share the same SwiftKitCore checkout but use separate plugin output
      // directories, so rebuilding for each module is redundant.
      if !FileManager.default.fileExists(atPath: swiftKitCoreClasspath) {
        try await runSubprocess(
          executable: gradleExecutable,
          arguments: [
            ":SwiftKitCore:classes",
            "--project-dir", gradleProjectDir,
            "--gradle-user-home", gradleUserHome,
            "--configure-on-demand",
            "--no-daemon",
          ],
          environment: .inherit.updating(["GRADLE_USER_HOME": gradleUserHome]),
          errorMessage: "gradle :SwiftKitCore:classes",
        )
      }

      // If the sources list does not exist, jextract produced no Java callbacks.
      // Write an empty placeholder Swift file and return early.
      guard FileManager.default.fileExists(atPath: javaSourcesList) else {
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        try "// No Java callbacks generated\n".write(
          to: outputFile,
          atomically: true,
          encoding: .utf8,
        )
        return
      }

      // 2. Compile Java sources with javac.
      try FileManager.default.createDirectory(
        atPath: javaOutputDirectory,
        withIntermediateDirectories: true,
      )

      // Dependency modules jextract writes to their respective directories, so
      // we need to consider them when we try to compile java output
      let dependencySourcePaths = dependencyJavaSourceDirs(
        javaSourcesList: javaSourcesList,
        dependsOn: dependsOn
      )

      var javacArgs: [String] = [
        "@\(javaSourcesList)",
        "-d", javaOutputDirectory,
        "-parameters",
        "-classpath", swiftKitCoreClasspath,
      ]
      // Consider dependency modules generated java sources as well
      if !dependencySourcePaths.isEmpty {
        javacArgs += ["-sourcepath", dependencySourcePaths.joined(separator: ":")]
      }

      try await runSubprocess(
        executable: javac,
        arguments: javacArgs,
        errorMessage: "javac",
      )

      // 3. Generate swift-java.config from compiled classes.
      //    Written into javaOutputDirectory (inside pluginWorkDirectory) but NOT
      //    declared as a build command output, so SPM will not bundle it as a resource.
      var configureArgs = [
        "configure",
        "--output-directory", javaOutputDirectory,
        "--cp", javaOutputDirectory,
        "--swift-module", swiftModule,
      ]
      if let prefix = swiftTypePrefix {
        configureArgs += ["--swift-type-prefix", prefix]
      }
      // Point `configure` at the real source config so it loads the correct
      // initial configuration (javaPackage, enableJavaCallbacks, ...) instead of
      // guessing `./Sources/<module>` — which is wrong for targets with a custom
      // SwiftPM `path:` (e.g. package-in-package layouts).
      if let swiftJavaConfig {
        configureArgs += ["--config", swiftJavaConfig]
      }

      try await runSubprocess(
        executable: swiftJavaTool,
        arguments: configureArgs,
        errorMessage: "swift-java configure",
      )

      // 4. Generate Swift wrappers using wrap-java.
      let configPath = URL(fileURLWithPath: javaOutputDirectory)
        .appendingPathComponent("swift-java.config").path

      var wrapJavaArgs = [
        "wrap-java",
        "--swift-module", swiftModule,
        "--output-directory", outputDirectory,
        "--config", configPath,
        "--cp", swiftKitCoreClasspath,
        "--single-swift-file-output", singleSwiftFileOutput,
      ]
      wrapJavaArgs += dependsOn.flatMap { ["--depends-on", $0] }

      try await runSubprocess(
        executable: swiftJavaTool,
        arguments: wrapJavaArgs,
        errorMessage: "swift-java wrap-java",
      )
    }
  }
}

// MARK: - Helpers

/// Find the plugin output path, walking up from a emitted generated source file
private func pluginOutputsRoot(forJavaSourcesList javaSourcesList: String) -> URL {
  let url = URL(fileURLWithPath: javaSourcesList)
  // Validate the expected SwiftPM plugin-outputs layout before stripping suffix.
  let expectedSuffix = [
    "destination",
    "JExtractSwiftPlugin",
    "src",
    "generated",
    "java",
    "jextract-generated-sources.txt",
  ]
  let comps = url.pathComponents
  precondition(
    comps.count >= expectedSuffix.count + 2
      && Array(comps.suffix(expectedSuffix.count)) == expectedSuffix,
    "javaSourcesList does not match the expected SwiftPM plugin-outputs layout: \(javaSourcesList)"
  )
  // Walk up: trailing fixed components + 1 consumer-module directory
  var root = url
  for _ in 0..<(expectedSuffix.count + 1) {
    root.deleteLastPathComponent()
  }
  return root
}

/// For each `--depends-on Module=...` entry, derive the dependency module's
/// generated Java directory.
private func dependencyJavaSourceDirs(
  javaSourcesList: String,
  dependsOn: [String]
) -> [String] {
  let pluginRoot = pluginOutputsRoot(forJavaSourcesList: javaSourcesList)
  let pluginOutputsRoot = pluginRoot.deletingLastPathComponent()
  let fm = FileManager.default
  var seen: Set<String> = []
  var paths: [String] = []

  func appendIfExists(_ candidate: URL) {
    let path = candidate.path
    guard fm.fileExists(atPath: path), seen.insert(path).inserted else {
      return
    }
    paths.append(path)
  }

  for arg in dependsOn {
    guard
      let parsed = try? parseDependsOnSyntax(arg),
      let moduleName = parsed.swiftModuleName, !moduleName.isEmpty
    else { continue }

    appendIfExists(
      pluginRoot
        .appendingPathComponent(moduleName)
        .appendingPathComponent("destination")
        .appendingPathComponent("JExtractSwiftPlugin")
        .appendingPathComponent("src")
        .appendingPathComponent("generated")
        .appendingPathComponent("java")
    )

    if let packageOutputDirs = try? fm.contentsOfDirectory(
      at: pluginOutputsRoot,
      includingPropertiesForKeys: nil
    ) {
      for packageOutputDir in packageOutputDirs {
        appendIfExists(
          packageOutputDir
            .appendingPathComponent(moduleName)
            .appendingPathComponent("destination")
            .appendingPathComponent("JExtractSwiftPlugin")
            .appendingPathComponent("src")
            .appendingPathComponent("generated")
            .appendingPathComponent("java")
        )
      }
    }
  }
  return paths
}

private func runSubprocess(
  executable: String,
  arguments: [String],
  environment: Subprocess.Environment = .inherit,
  errorMessage: String,
) async throws {
  let result = try await Subprocess.run(
    .path(FilePath(executable)),
    arguments: .init(arguments),
    environment: environment,
    output: .standardOutput,
    error: .standardError,
  )
  guard result.terminationStatus.isSuccess else {
    throw JavaCallbacksBuildError(
      "\(errorMessage) failed with exit status \(result.terminationStatus)"
    )
  }
}

struct JavaCallbacksBuildError: Error, CustomStringConvertible {
  let description: String
  init(_ message: String) { self.description = message }
}
