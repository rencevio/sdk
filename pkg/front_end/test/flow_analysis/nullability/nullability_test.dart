// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io' show Directory, Platform;
import 'package:front_end/src/api_prototype/experimental_flags.dart'
    show ExperimentalFlag;

import 'package:front_end/src/testing/id.dart' show ActualData, Id;
import 'package:front_end/src/testing/id_testing.dart'
    show DataInterpreter, runTests;
import 'package:front_end/src/testing/id_testing.dart';
import 'package:front_end/src/testing/id_testing_helper.dart';
import 'package:kernel/ast.dart' hide Variance;

main(List<String> args) async {
  Directory dataDir = new Directory.fromUri(Platform.script.resolve('data'));
  await runTests(dataDir,
      args: args,
      supportedMarkers: sharedMarkers,
      createUriForFileName: createUriForFileName,
      onFailure: onFailure,
      runTest: runTestFor(const NullabilityDataComputer(), [
        new TestConfig(cfeMarker, 'cfe with nnbd',
            experimentalFlags: const {ExperimentalFlag.nonNullable: true})
      ]),
      skipList: [
        // TODO(dmitryas): Run all nullability tests.
        'assign.dart',
        'if.dart',
        'is.dart',
        'logical.dart',
        'null_aware_access.dart',
        'null_check.dart',
        'potentially_mutated_in_closure.dart',
        'try_finally.dart',
        'while.dart',
      ]);
}

class NullabilityDataComputer extends DataComputer<String> {
  const NullabilityDataComputer();

  @override
  DataInterpreter<String> get dataValidator => const StringDataInterpreter();

  /// Function that computes a data mapping for [member].
  ///
  /// Fills [actualMap] with the data.
  void computeMemberData(InternalCompilerResult compilerResult, Member member,
      Map<Id, ActualData<String>> actualMap,
      {bool verbose}) {
    member.accept(new NullabilityDataExtractor(compilerResult, actualMap));
  }
}

class NullabilityDataExtractor extends CfeDataExtractor<String> {
  NullabilityDataExtractor(InternalCompilerResult compilerResult,
      Map<Id, ActualData<String>> actualMap)
      : super(compilerResult, actualMap);

  @override
  String computeNodeValue(Id id, TreeNode node) {
    if (node is VariableGet && node.promotedType != null) {
      if (node.variable.type.nullability != Nullability.nonNullable &&
          node.promotedType.nullability == Nullability.nonNullable) {
        return 'nonNullable';
      }
    }
    return null;
  }
}
