// Copyright (c) 2017, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

import 'package:kernel/ast.dart'
    show
        Constructor,
        DartType,
        DartTypeVisitor,
        DynamicType,
        Field,
        FunctionType,
        InterfaceType,
        Member,
        NamedType,
        Nullability,
        TreeNode,
        TypeParameter,
        TypeParameterType,
        TypedefType,
        VariableDeclaration;

import 'package:kernel/class_hierarchy.dart' show ClassHierarchy;

import 'package:kernel/core_types.dart' show CoreTypes;

import 'package:kernel/type_environment.dart';

import '../../base/instrumentation.dart' show Instrumentation;

import '../builder/library_builder.dart';

import '../flow_analysis/flow_analysis.dart';

import '../kernel/forest.dart';

import '../kernel/kernel_builder.dart'
    show ClassHierarchyBuilder, ImplicitFieldType;

import '../source/source_library_builder.dart' show SourceLibraryBuilder;

import 'type_inferrer.dart';

import 'type_schema_environment.dart' show TypeSchemaEnvironment;

enum Variance {
  covariant,
  contravariant,
  invariant,
}

Variance invertVariance(Variance variance) {
  switch (variance) {
    case Variance.covariant:
      return Variance.contravariant;
    case Variance.contravariant:
      return Variance.covariant;
    case Variance.invariant:
  }
  return variance;
}

/// Visitor to check whether a given type mentions any of a class's type
/// parameters in a non-covariant fashion.
class IncludesTypeParametersNonCovariantly extends DartTypeVisitor<bool> {
  Variance _variance;

  final List<TypeParameter> _typeParametersToSearchFor;

  IncludesTypeParametersNonCovariantly(this._typeParametersToSearchFor,
      {Variance initialVariance})
      : _variance = initialVariance;

  @override
  bool defaultDartType(DartType node) => false;

  @override
  bool visitFunctionType(FunctionType node) {
    if (node.returnType.accept(this)) return true;
    Variance oldVariance = _variance;
    _variance = Variance.invariant;
    for (TypeParameter parameter in node.typeParameters) {
      if (parameter.bound.accept(this)) return true;
    }
    _variance = invertVariance(oldVariance);
    for (DartType parameter in node.positionalParameters) {
      if (parameter.accept(this)) return true;
    }
    for (NamedType parameter in node.namedParameters) {
      if (parameter.type.accept(this)) return true;
    }
    _variance = oldVariance;
    return false;
  }

  @override
  bool visitInterfaceType(InterfaceType node) {
    for (DartType argument in node.typeArguments) {
      if (argument.accept(this)) return true;
    }
    return false;
  }

  @override
  bool visitTypedefType(TypedefType node) {
    return node.unalias.accept(this);
  }

  @override
  bool visitTypeParameterType(TypeParameterType node) {
    return _variance != Variance.covariant &&
        _typeParametersToSearchFor.contains(node.parameter);
  }
}

/// Keeps track of the global state for the type inference that occurs outside
/// of method bodies and initializers.
///
/// This class describes the interface for use by clients of type inference
/// (e.g. DietListener).  Derived classes should derive from
/// [TypeInferenceEngineImpl].
abstract class TypeInferenceEngine {
  ClassHierarchy classHierarchy;

  ClassHierarchyBuilder hierarchyBuilder;

  CoreTypes coreTypes;

  // TODO(johnniwinther): Shared this with the BodyBuilder.
  final Forest forest = const Forest();

  /// Indicates whether the "prepare" phase of type inference is complete.
  bool isTypeInferencePrepared = false;

  TypeSchemaEnvironment typeSchemaEnvironment;

  /// A map containing constructors with initializing formals whose types
  /// need to be inferred.
  ///
  /// This is represented as a map from a constructor to its library
  /// builder because the builder is used to report errors due to cyclic
  /// inference dependencies.
  final Map<Constructor, LibraryBuilder> toBeInferred = {};

  /// A map containing constructors in the process of being inferred.
  ///
  /// This is used to detect cyclic inference dependencies.  It is represented
  /// as a map from a constructor to its library builder because the builder
  /// is used to report errors.
  final Map<Constructor, LibraryBuilder> beingInferred = {};

  final Instrumentation instrumentation;

  TypeInferenceEngine(this.instrumentation);

  /// Creates a type inferrer for use inside of a method body declared in a file
  /// with the given [uri].
  TypeInferrer createLocalTypeInferrer(Uri uri, InterfaceType thisType,
      SourceLibraryBuilder library, InferenceDataForTesting dataForTesting);

  /// Creates a [TypeInferrer] object which is ready to perform type inference
  /// on the given [field].
  TypeInferrer createTopLevelTypeInferrer(Uri uri, InterfaceType thisType,
      SourceLibraryBuilder library, InferenceDataForTesting dataForTesting);

  /// Performs the third phase of top level inference, which is to visit all
  /// constructors still needing inference and infer the types of their
  /// initializing formals from the corresponding fields.
  void finishTopLevelInitializingFormals() {
    // Field types have all been inferred so there cannot be a cyclic
    // dependency.
    for (Constructor constructor in toBeInferred.keys) {
      for (VariableDeclaration declaration
          in constructor.function.positionalParameters) {
        inferInitializingFormal(declaration, constructor);
      }
      for (VariableDeclaration declaration
          in constructor.function.namedParameters) {
        inferInitializingFormal(declaration, constructor);
      }
    }
    toBeInferred.clear();
  }

  void inferInitializingFormal(VariableDeclaration formal, Constructor parent) {
    if (formal.type == null) {
      for (Field field in parent.enclosingClass.fields) {
        if (field.name.name == formal.name) {
          TypeInferenceEngine.resolveInferenceNode(field);
          formal.type = field.type;
          return;
        }
      }
      // We did not find the corresponding field, so the program is erroneous.
      // The error should have been reported elsewhere and type inference
      // should continue by inferring dynamic.
      formal.type = const DynamicType();
    }
  }

  /// Gets ready to do top level type inference for the component having the
  /// given [hierarchy], using the given [coreTypes].
  void prepareTopLevel(CoreTypes coreTypes, ClassHierarchy hierarchy) {
    this.coreTypes = coreTypes;
    this.classHierarchy = hierarchy;
    this.typeSchemaEnvironment =
        new TypeSchemaEnvironment(coreTypes, hierarchy);
  }

  static Member resolveInferenceNode(Member member) {
    if (member is Field) {
      DartType type = member.type;
      if (type is ImplicitFieldType) {
        if (type.memberBuilder.member != member) {
          type.memberBuilder.inferCopiedType(member);
        } else {
          type.memberBuilder.inferType();
        }
      }
    }
    return member;
  }
}

/// Concrete implementation of [TypeInferenceEngine] specialized to work with
/// kernel objects.
class TypeInferenceEngineImpl extends TypeInferenceEngine {
  TypeInferenceEngineImpl(Instrumentation instrumentation)
      : super(instrumentation);

  @override
  TypeInferrer createLocalTypeInferrer(Uri uri, InterfaceType thisType,
      SourceLibraryBuilder library, InferenceDataForTesting dataForTesting) {
    AssignedVariables<TreeNode, VariableDeclaration> assignedVariables;
    if (dataForTesting != null) {
      assignedVariables = dataForTesting.flowAnalysisResult.assignedVariables =
          new AssignedVariablesForTesting<TreeNode, VariableDeclaration>();
    } else {
      assignedVariables =
          new AssignedVariables<TreeNode, VariableDeclaration>();
    }
    return new TypeInferrerImpl(
        this, uri, false, thisType, library, assignedVariables, dataForTesting);
  }

  @override
  TypeInferrer createTopLevelTypeInferrer(Uri uri, InterfaceType thisType,
      SourceLibraryBuilder library, InferenceDataForTesting dataForTesting) {
    AssignedVariables<TreeNode, VariableDeclaration> assignedVariables;
    if (dataForTesting != null) {
      assignedVariables = dataForTesting.flowAnalysisResult.assignedVariables =
          new AssignedVariablesForTesting<TreeNode, VariableDeclaration>();
    } else {
      assignedVariables =
          new AssignedVariables<TreeNode, VariableDeclaration>();
    }
    return new TypeInferrerImpl(
        this, uri, true, thisType, library, assignedVariables, dataForTesting);
  }
}

class InferenceDataForTesting {
  final FlowAnalysisResult flowAnalysisResult = new FlowAnalysisResult();
}

/// The result of performing flow analysis on a unit.
class FlowAnalysisResult {
  /// The list of nodes, [Expression]s or [Statement]s, that cannot be reached,
  /// for example because a previous statement always exits.
  final List<TreeNode> unreachableNodes = [];

  /// The list of function bodies that don't complete, for example because
  /// there is a `return` statement at the end of the function body block.
  final List<TreeNode> functionBodiesThatDontComplete = [];

  /// The list of [Expression]s representing variable accesses that occur before
  /// the corresponding variable has been definitely assigned.
  final List<TreeNode> unassignedNodes = [];

  /// The assigned variables information that computed for the member.
  AssignedVariablesForTesting<TreeNode, VariableDeclaration> assignedVariables;
}

/// CFE-specific implementation of [TypeOperations].
class TypeOperationsCfe
    implements TypeOperations<VariableDeclaration, DartType> {
  final TypeEnvironment typeEnvironment;

  TypeOperationsCfe(this.typeEnvironment);

  // TODO(dmitryas): Consider checking for mutual subtypes instead of ==.
  @override
  bool isSameType(DartType type1, DartType type2) => type1 == type2;

  @override
  bool isSubtypeOf(DartType leftType, DartType rightType) {
    return typeEnvironment.isSubtypeOf(
        leftType, rightType, SubtypeCheckMode.withNullabilities);
  }

  @override
  DartType promoteToNonNull(DartType type) {
    return type.withNullability(Nullability.nonNullable);
  }

  @override
  DartType variableType(VariableDeclaration variable) => variable.type;

  @override
  DartType tryPromoteToType(DartType from, DartType to) {
    if (from is TypeParameterType) {
      return new TypeParameterType(from.parameter, to, from.nullability);
    }
    return to;
  }
}
