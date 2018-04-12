// Copyright 2015 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'artifacts.dart';
import 'asset.dart';
import 'base/build.dart';
import 'base/common.dart';
import 'base/file_system.dart';
import 'build_info.dart';
import 'compile.dart';
import 'dart/package_map.dart';
import 'devfs.dart';
import 'globals.dart';
import 'zip.dart';

const String defaultMainPath = 'lib/main.dart';
const String defaultAssetBasePath = '.';
const String defaultManifestPath = 'pubspec.yaml';
String get defaultFlxOutputPath => fs.path.join(getBuildDirectory(), 'app.flx');
String get defaultSnapshotPath => fs.path.join(getBuildDirectory(), 'snapshot_blob.bin');
String get defaultDepfilePath => fs.path.join(getBuildDirectory(), 'snapshot_blob.bin.d');
String get defaultApplicationKernelPath => fs.path.join(getBuildDirectory(), 'app.dill');
const String defaultPrivateKeyPath = 'privatekey.der';

const String _kKernelKey = 'kernel_blob.bin';
const String _kSnapshotKey = 'snapshot_blob.bin';
const String _kDylibKey = 'libapp.so';
const String _kPlatformKernelKey = 'platform.dill';

Future<Null> build({
  String mainPath: defaultMainPath,
  String manifestPath: defaultManifestPath,
  String outputPath,
  String snapshotPath,
  String applicationKernelFilePath,
  String depfilePath,
  String privateKeyPath: defaultPrivateKeyPath,
  String workingDirPath,
  String packagesPath,
  bool previewDart2 : false,
  bool precompiledSnapshot: false,
  bool reportLicensedPackages: false,
  bool trackWidgetCreation: false,
  List<String> fileSystemRoots,
  String fileSystemScheme,
}) async {
  outputPath ??= defaultFlxOutputPath;
  snapshotPath ??= defaultSnapshotPath;
  depfilePath ??= defaultDepfilePath;
  workingDirPath ??= getAssetBuildDirectory();
  packagesPath ??= fs.path.absolute(PackageMap.globalPackagesPath);
  applicationKernelFilePath ??= defaultApplicationKernelPath;
  File snapshotFile;

  if (!precompiledSnapshot && !previewDart2) {
    ensureDirectoryExists(snapshotPath);

    // In a precompiled snapshot, the instruction buffer contains script
    // content equivalents
    final Snapshotter snapshotter = new Snapshotter();
    final int result = await snapshotter.buildScriptSnapshot(
      mainPath: mainPath,
      snapshotPath: snapshotPath,
      depfilePath: depfilePath,
      packagesPath: packagesPath,
    );
    if (result != 0)
      throwToolExit('Failed to run the Flutter compiler. Exit code: $result', exitCode: result);

    snapshotFile = fs.file(snapshotPath);
  }

  DevFSContent kernelContent;
  if (!precompiledSnapshot && previewDart2) {
    final File fingerprintFile = fs.file('$depfilePath.fingerprint');
    final List<String> inputPaths = <String>[
      mainPath,
    ];

    bool needBuild = true;
    final List<File> fingerprintFiles = <File>[fingerprintFile, fs.file(depfilePath)]
      ..addAll(inputPaths.map(fs.file));

    Future<Fingerprint> makeFingerprint() async {
      final Set<String> compilerInputPaths = await readDepfile(depfilePath)
        ..add(mainPath);
      final Map<String, String> properties = <String, String>{
        'entryPoint': mainPath,
      };
      return new Fingerprint.fromBuildInputs(properties, compilerInputPaths);
    }

    if (fingerprintFiles.every((File file) => file.existsSync())) {
      try {
        final String json = await fingerprintFile.readAsString();
        final Fingerprint oldFingerprint = new Fingerprint.fromJson(json);
        if (oldFingerprint == await makeFingerprint()) {
          needBuild = false;
          printStatus('Skipping compilation. Fingerprint match.');
        }
      } catch (e) {
        printTrace('Rebuilding kernel file due to fingerprint check error: $e');
      }
    }

    String kernelBinaryFilename;
    if (needBuild) {
      ensureDirectoryExists(applicationKernelFilePath);
      kernelBinaryFilename = await compile(
        sdkRoot: artifacts.getArtifactPath(Artifact.flutterPatchedSdkPath),
        incrementalCompilerByteStorePath: fs.path.absolute(getIncrementalCompilerByteStoreDirectory()),
        mainPath: fs.file(mainPath).absolute.path,
        outputFilePath: applicationKernelFilePath,
        depFilePath: depfilePath,
        trackWidgetCreation: trackWidgetCreation,
        fileSystemRoots: fileSystemRoots,
        fileSystemScheme: fileSystemScheme,
        packagesPath: packagesPath,
      );
      if (kernelBinaryFilename == null) {
        throwToolExit('Compiler failed on $mainPath');
      }
      // Compute and record build fingerprint.
      try {
        final Fingerprint fingerprint = await makeFingerprint();
        await fingerprintFile.writeAsString(fingerprint.toJson());
      } catch (e, s) {
        // Log exception and continue, this step is a performance improvement only.
        printStatus('Error during compilation output fingerprinting: $e\n$s');
      }
    } else {
      kernelBinaryFilename = applicationKernelFilePath;
    }
    kernelContent = new DevFSFileContent(fs.file(kernelBinaryFilename));

    await fs.directory(getBuildDirectory()).childFile('frontend_server.d')
        .writeAsString('frontend_server.d: ${artifacts.getArtifactPath(Artifact.frontendServerSnapshotForEngineDartSdk)}\n');
  }

  final AssetBundle assets = await buildAssets(
    manifestPath: manifestPath,
    workingDirPath: workingDirPath,
    packagesPath: packagesPath,
    reportLicensedPackages: reportLicensedPackages,
  );
  if (assets == null)
    throwToolExit('Error building assets for $outputPath', exitCode: 1);

  return assemble(
    assetBundle: assets,
    kernelContent: kernelContent,
    snapshotFile: snapshotFile,
    outputPath: outputPath,
    privateKeyPath: privateKeyPath,
    workingDirPath: workingDirPath,
  ).then((_) => null);
}

Future<AssetBundle> buildAssets({
  String manifestPath,
  String workingDirPath,
  String packagesPath,
  bool includeDefaultFonts: true,
  bool reportLicensedPackages: false
}) async {
  workingDirPath ??= getAssetBuildDirectory();
  packagesPath ??= fs.path.absolute(PackageMap.globalPackagesPath);

  // Build the asset bundle.
  final AssetBundle assetBundle = AssetBundleFactory.instance.createBundle();
  final int result = await assetBundle.build(
    manifestPath: manifestPath,
    workingDirPath: workingDirPath,
    packagesPath: packagesPath,
    includeDefaultFonts: includeDefaultFonts,
    reportLicensedPackages: reportLicensedPackages
  );
  if (result != 0)
    return null;

  return assetBundle;
}

Future<List<String>> assemble({
  AssetBundle assetBundle,
  DevFSContent kernelContent,
  File snapshotFile,
  File dylibFile,
  String outputPath,
  String privateKeyPath: defaultPrivateKeyPath,
  String workingDirPath,
}) async {
  outputPath ??= defaultFlxOutputPath;
  workingDirPath ??= getAssetBuildDirectory();
  printTrace('Building $outputPath');

  final ZipBuilder zipBuilder = new ZipBuilder();

  // Add all entries from the asset bundle.
  zipBuilder.entries.addAll(assetBundle.entries);

  final List<String> fileDependencies = assetBundle.entries.values
      .expand((DevFSContent content) => content.fileDependencies)
      .toList();

  if (kernelContent != null) {
    final String platformKernelDill = artifacts.getArtifactPath(Artifact.platformKernelDill);
    zipBuilder.entries[_kKernelKey] = kernelContent;
    zipBuilder.entries[_kPlatformKernelKey] = new DevFSFileContent(fs.file(platformKernelDill));
  }
  if (snapshotFile != null)
    zipBuilder.entries[_kSnapshotKey] = new DevFSFileContent(snapshotFile);
  if (dylibFile != null)
    zipBuilder.entries[_kDylibKey] = new DevFSFileContent(dylibFile);

  ensureDirectoryExists(outputPath);

  printTrace('Encoding zip file to $outputPath');

  // TODO(zarah): Remove the zipBuilder and write the files directly once FLX
  // is deprecated.

  await zipBuilder.createZip(fs.file(outputPath), fs.directory(workingDirPath));

  printTrace('Built $outputPath.');

  return fileDependencies;
}
