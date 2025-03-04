// Copyright (c) 2014, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:collection';

import 'package:analyzer/dart/analysis/session.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/error/error.dart';
import 'package:analyzer/src/dart/constant/compute.dart';
import 'package:analyzer/src/dart/constant/evaluation.dart';
import 'package:analyzer/src/dart/constant/value.dart';
import 'package:analyzer/src/dart/element/type.dart';
import 'package:analyzer/src/dart/element/type_algebra.dart';
import 'package:analyzer/src/generated/constant.dart' show EvaluationResultImpl;
import 'package:analyzer/src/generated/engine.dart'
    show AnalysisContext, AnalysisEngine, AnalysisOptionsImpl;
import 'package:analyzer/src/generated/java_engine.dart';
import 'package:analyzer/src/generated/resolver.dart';
import 'package:analyzer/src/generated/sdk.dart' show DartSdk;
import 'package:analyzer/src/generated/source.dart';
import 'package:analyzer/src/generated/utilities_collection.dart';
import 'package:analyzer/src/generated/utilities_dart.dart';
import 'package:analyzer/src/generated/utilities_general.dart';
import 'package:analyzer/src/summary/idl.dart';
import 'package:analyzer/src/summary2/linked_unit_context.dart';
import 'package:analyzer/src/summary2/reference.dart';
import 'package:analyzer/src/util/comment.dart';
import 'package:meta/meta.dart';

/// A concrete implementation of a [ClassElement].
abstract class AbstractClassElementImpl extends ElementImpl
    implements ClassElement {
  /// The type defined by the class.
  InterfaceType _thisType;

  /// A list containing all of the accessors (getters and setters) contained in
  /// this class.
  List<PropertyAccessorElement> _accessors;

  /// A list containing all of the fields contained in this class.
  List<FieldElement> _fields;

  /// A list containing all of the methods contained in this class.
  List<MethodElement> _methods;

  /// Initialize a newly created class element to have the given [name] at the
  /// given [offset] in the file that contains the declaration of this element.
  AbstractClassElementImpl(String name, int offset) : super(name, offset);

  AbstractClassElementImpl.forLinkedNode(
      ElementImpl enclosing, Reference reference, AstNode linkedNode)
      : super.forLinkedNode(enclosing, reference, linkedNode);

  /// Initialize a newly created class element to have the given [name].
  AbstractClassElementImpl.forNode(Identifier name) : super.forNode(name);

  /// Initialize using the given serialized information.
  AbstractClassElementImpl.forSerialized(
      CompilationUnitElementImpl enclosingUnit)
      : super.forSerialized(enclosingUnit);

  @override
  List<PropertyAccessorElement> get accessors {
    return _accessors ?? const <PropertyAccessorElement>[];
  }

  /// Set the accessors contained in this class to the given [accessors].
  void set accessors(List<PropertyAccessorElement> accessors) {
    for (PropertyAccessorElement accessor in accessors) {
      (accessor as PropertyAccessorElementImpl).enclosingElement = this;
    }
    this._accessors = accessors;
  }

  @override
  String get displayName => name;

  @override
  List<FieldElement> get fields => _fields ?? const <FieldElement>[];

  /// Set the fields contained in this class to the given [fields].
  void set fields(List<FieldElement> fields) {
    for (FieldElement field in fields) {
      (field as FieldElementImpl).enclosingElement = this;
    }
    this._fields = fields;
  }

  @override
  bool get isDartCoreObject => false;

  @override
  bool get isEnum => false;

  @override
  bool get isMixin => false;

  @override
  ElementKind get kind => ElementKind.CLASS;

  @override
  List<InterfaceType> get superclassConstraints => const <InterfaceType>[];

  @override
  InterfaceType get thisType {
    if (_thisType == null) {
      List<DartType> typeArguments;
      if (typeParameters.isNotEmpty) {
        typeArguments = typeParameters.map<DartType>((t) {
          return t.instantiate(nullabilitySuffix: _noneOrStarSuffix);
        }).toList();
      } else {
        typeArguments = const <DartType>[];
      }
      return _thisType = instantiate(
        typeArguments: typeArguments,
        nullabilitySuffix: _noneOrStarSuffix,
      );
    }
    return _thisType;
  }

  @override
  T accept<T>(ElementVisitor<T> visitor) => visitor.visitClassElement(this);

  @override
  ElementImpl getChild(String identifier) {
    //
    // The casts in this method are safe because the set methods would have
    // thrown a CCE if any of the elements in the arrays were not of the
    // expected types.
    //
    for (PropertyAccessorElement accessor in accessors) {
      PropertyAccessorElementImpl accessorImpl = accessor;
      if (accessorImpl.identifier == identifier) {
        return accessorImpl;
      }
    }
    for (FieldElement field in fields) {
      FieldElementImpl fieldImpl = field;
      if (fieldImpl.identifier == identifier) {
        return fieldImpl;
      }
    }
    return null;
  }

  @override
  FieldElement getField(String name) {
    for (FieldElement fieldElement in fields) {
      if (name == fieldElement.name) {
        return fieldElement;
      }
    }
    return null;
  }

  @override
  PropertyAccessorElement getGetter(String getterName) {
    int length = accessors.length;
    for (int i = 0; i < length; i++) {
      PropertyAccessorElement accessor = accessors[i];
      if (accessor.isGetter && accessor.name == getterName) {
        return accessor;
      }
    }
    return null;
  }

  @override
  MethodElement getMethod(String methodName) {
    int length = methods.length;
    for (int i = 0; i < length; i++) {
      MethodElement method = methods[i];
      if (method.name == methodName) {
        return method;
      }
    }
    return null;
  }

  @override
  PropertyAccessorElement getSetter(String setterName) {
    return getSetterFromAccessors(setterName, accessors);
  }

  @override
  InterfaceType instantiate({
    @required List<DartType> typeArguments,
    @required NullabilitySuffix nullabilitySuffix,
  }) {
    if (typeArguments.length != typeParameters.length) {
      var ta = 'typeArguments.length (${typeArguments.length})';
      var tp = 'typeParameters.length (${typeParameters.length})';
      throw ArgumentError('$ta != $tp');
    }
    return InterfaceTypeImpl.explicit(
      this,
      typeArguments,
      nullabilitySuffix: nullabilitySuffix,
    );
  }

  @override
  MethodElement lookUpConcreteMethod(
          String methodName, LibraryElement library) =>
      _first(getImplementationsOfMethod(this, methodName).where(
          (MethodElement method) =>
              !method.isAbstract && method.isAccessibleIn(library)));

  @override
  PropertyAccessorElement lookUpGetter(
          String getterName, LibraryElement library) =>
      _first(_implementationsOfGetter(getterName).where(
          (PropertyAccessorElement getter) => getter.isAccessibleIn(library)));

  @override
  PropertyAccessorElement lookUpInheritedConcreteGetter(
          String getterName, LibraryElement library) =>
      _first(_implementationsOfGetter(getterName).where(
          (PropertyAccessorElement getter) =>
              !getter.isAbstract &&
              getter.isAccessibleIn(library) &&
              getter.enclosingElement != this));

  ExecutableElement lookUpInheritedConcreteMember(
      String name, LibraryElement library) {
    if (name.endsWith('=')) {
      return lookUpInheritedConcreteSetter(name, library);
    } else {
      return lookUpInheritedConcreteMethod(name, library) ??
          lookUpInheritedConcreteGetter(name, library);
    }
  }

  @override
  MethodElement lookUpInheritedConcreteMethod(
          String methodName, LibraryElement library) =>
      _first(getImplementationsOfMethod(this, methodName).where(
          (MethodElement method) =>
              !method.isAbstract &&
              method.isAccessibleIn(library) &&
              method.enclosingElement != this));

  @override
  PropertyAccessorElement lookUpInheritedConcreteSetter(
          String setterName, LibraryElement library) =>
      _first(_implementationsOfSetter(setterName).where(
          (PropertyAccessorElement setter) =>
              !setter.isAbstract &&
              setter.isAccessibleIn(library) &&
              setter.enclosingElement != this));

  @override
  MethodElement lookUpInheritedMethod(
          String methodName, LibraryElement library) =>
      _first(getImplementationsOfMethod(this, methodName).where(
          (MethodElement method) =>
              method.isAccessibleIn(library) &&
              method.enclosingElement != this));

  @override
  MethodElement lookUpMethod(String methodName, LibraryElement library) =>
      lookUpMethodInClass(this, methodName, library);

  @override
  PropertyAccessorElement lookUpSetter(
          String setterName, LibraryElement library) =>
      _first(_implementationsOfSetter(setterName).where(
          (PropertyAccessorElement setter) => setter.isAccessibleIn(library)));

  @override
  void visitChildren(ElementVisitor visitor) {
    super.visitChildren(visitor);
    safelyVisitChildren(accessors, visitor);
    safelyVisitChildren(fields, visitor);
  }

  /// Return an iterable containing all of the implementations of a getter with
  /// the given [getterName] that are defined in this class any any superclass
  /// of this class (but not in interfaces).
  ///
  /// The getters that are returned are not filtered in any way. In particular,
  /// they can include getters that are not visible in some context. Clients
  /// must perform any necessary filtering.
  ///
  /// The getters are returned based on the depth of their defining class; if
  /// this class contains a definition of the getter it will occur first, if
  /// Object contains a definition of the getter it will occur last.
  Iterable<PropertyAccessorElement> _implementationsOfGetter(
      String getterName) sync* {
    ClassElement classElement = this;
    HashSet<ClassElement> visitedClasses = new HashSet<ClassElement>();
    while (classElement != null && visitedClasses.add(classElement)) {
      PropertyAccessorElement getter = classElement.getGetter(getterName);
      if (getter != null) {
        yield getter;
      }
      for (InterfaceType mixin in classElement.mixins.reversed) {
        getter = mixin.element?.getGetter(getterName);
        if (getter != null) {
          yield getter;
        }
      }
      classElement = classElement.supertype?.element;
    }
  }

  /// Return an iterable containing all of the implementations of a setter with
  /// the given [setterName] that are defined in this class any any superclass
  /// of this class (but not in interfaces).
  ///
  /// The setters that are returned are not filtered in any way. In particular,
  /// they can include setters that are not visible in some context. Clients
  /// must perform any necessary filtering.
  ///
  /// The setters are returned based on the depth of their defining class; if
  /// this class contains a definition of the setter it will occur first, if
  /// Object contains a definition of the setter it will occur last.
  Iterable<PropertyAccessorElement> _implementationsOfSetter(
      String setterName) sync* {
    ClassElement classElement = this;
    HashSet<ClassElement> visitedClasses = new HashSet<ClassElement>();
    while (classElement != null && visitedClasses.add(classElement)) {
      PropertyAccessorElement setter = classElement.getSetter(setterName);
      if (setter != null) {
        yield setter;
      }
      for (InterfaceType mixin in classElement.mixins.reversed) {
        setter = mixin.element?.getSetter(setterName);
        if (setter != null) {
          yield setter;
        }
      }
      classElement = classElement.supertype?.element;
    }
  }

  /// Return an iterable containing all of the implementations of a method with
  /// the given [methodName] that are defined in this class any any superclass
  /// of this class (but not in interfaces).
  ///
  /// The methods that are returned are not filtered in any way. In particular,
  /// they can include methods that are not visible in some context. Clients
  /// must perform any necessary filtering.
  ///
  /// The methods are returned based on the depth of their defining class; if
  /// this class contains a definition of the method it will occur first, if
  /// Object contains a definition of the method it will occur last.
  static Iterable<MethodElement> getImplementationsOfMethod(
      ClassElement classElement, String methodName) sync* {
    HashSet<ClassElement> visitedClasses = new HashSet<ClassElement>();
    while (classElement != null && visitedClasses.add(classElement)) {
      MethodElement method = classElement.getMethod(methodName);
      if (method != null) {
        yield method;
      }
      for (InterfaceType mixin in classElement.mixins.reversed) {
        method = mixin.element?.getMethod(methodName);
        if (method != null) {
          yield method;
        }
      }
      classElement = classElement.supertype?.element;
    }
  }

  static PropertyAccessorElement getSetterFromAccessors(
      String setterName, List<PropertyAccessorElement> accessors) {
    // TODO (jwren) revisit- should we append '=' here or require clients to
    // include it?
    // Do we need the check for isSetter below?
    if (!StringUtilities.endsWithChar(setterName, 0x3D)) {
      setterName += '=';
    }
    for (PropertyAccessorElement accessor in accessors) {
      if (accessor.isSetter && accessor.name == setterName) {
        return accessor;
      }
    }
    return null;
  }

  static MethodElement lookUpMethodInClass(
      ClassElement classElement, String methodName, LibraryElement library) {
    return _first(getImplementationsOfMethod(classElement, methodName)
        .where((MethodElement method) => method.isAccessibleIn(library)));
  }

  /// Return the first element from the given [iterable], or `null` if the
  /// iterable is empty.
  static E _first<E>(Iterable<E> iterable) {
    if (iterable.isEmpty) {
      return null;
    }
    return iterable.first;
  }
}

/// For AST nodes that could be in both the getter and setter contexts
/// ([IndexExpression]s and [SimpleIdentifier]s), the additional resolved
/// element (getter) is stored in the AST node, in an [AuxiliaryElements].
class AuxiliaryElements {
  /// The element based on static type information, or `null` if the AST
  /// structure has not been resolved or if the node could not be resolved.
  final ExecutableElement staticElement;

  AuxiliaryElements(this.staticElement);
}

/// An [AbstractClassElementImpl] which is a class.
class ClassElementImpl extends AbstractClassElementImpl
    with TypeParameterizedElementMixin {
  /// The superclass of the class, or `null` for [Object].
  InterfaceType _supertype;

  /// The type defined by the class.
  InterfaceType _type;

  /// A list containing all of the mixins that are applied to the class being
  /// extended in order to derive the superclass of this class.
  List<InterfaceType> _mixins;

  /// A list containing all of the interfaces that are implemented by this
  /// class.
  List<InterfaceType> _interfaces;

  /// For classes which are not mixin applications, a list containing all of the
  /// constructors contained in this class, or `null` if the list of
  /// constructors has not yet been built.
  ///
  /// For classes which are mixin applications, the list of constructors is
  /// computed on the fly by the [constructors] getter, and this field is
  /// `null`.
  List<ConstructorElement> _constructors;

  /// A flag indicating whether the types associated with the instance members
  /// of this class have been inferred.
  bool _hasBeenInferred = false;

  /// This callback is set during mixins inference to handle reentrant calls.
  List<InterfaceType> Function(ClassElementImpl) linkedMixinInferenceCallback;

  /// Initialize a newly created class element to have the given [name] at the
  /// given [offset] in the file that contains the declaration of this element.
  ClassElementImpl(String name, int offset) : super(name, offset);

  ClassElementImpl.forLinkedNode(CompilationUnitElementImpl enclosing,
      Reference reference, AstNode linkedNode)
      : super.forLinkedNode(enclosing, reference, linkedNode);

  /// Initialize a newly created class element to have the given [name].
  ClassElementImpl.forNode(Identifier name) : super.forNode(name);

  @override
  List<PropertyAccessorElement> get accessors {
    if (_accessors != null) return _accessors;

    if (linkedNode != null) {
      if (linkedNode is ClassOrMixinDeclaration) {
        _createPropertiesAndAccessors();
        assert(_accessors != null);
        return _accessors;
      } else {
        return _accessors = const [];
      }
    }

    return _accessors ??= const <PropertyAccessorElement>[];
  }

  @override
  List<InterfaceType> get allSupertypes {
    List<InterfaceType> list = new List<InterfaceType>();
    collectAllSupertypes(list, thisType, thisType);
    return list;
  }

  @override
  int get codeLength {
    if (linkedNode != null) {
      return linkedContext.getCodeLength(linkedNode);
    }
    return super.codeLength;
  }

  @override
  int get codeOffset {
    if (linkedNode != null) {
      return linkedContext.getCodeOffset(linkedNode);
    }
    return super.codeOffset;
  }

  @override
  List<ConstructorElement> get constructors {
    if (_constructors != null) {
      return _constructors;
    }

    if (isMixinApplication) {
      return _constructors = _computeMixinAppConstructors();
    }

    if (linkedNode != null) {
      var context = enclosingUnit.linkedContext;
      var containerRef = reference.getChild('@constructor');
      _constructors = context.getConstructors(linkedNode).map((node) {
        var name = node.name?.name ?? '';
        var reference = containerRef.getChild(name);
        if (reference.hasElementFor(node)) {
          return reference.element as ConstructorElement;
        }
        return ConstructorElementImpl.forLinkedNode(this, reference, node);
      }).toList();

      if (_constructors.isEmpty) {
        return _constructors = [
          ConstructorElementImpl.forLinkedNode(
            this,
            containerRef.getChild(''),
            null,
          )
            ..isSynthetic = true
            ..name = ''
            ..nameOffset = -1,
        ];
      }
    }

    if (_constructors.isEmpty) {
      var constructor = new ConstructorElementImpl('', -1);
      constructor.isSynthetic = true;
      constructor.enclosingElement = this;
      _constructors = <ConstructorElement>[constructor];
    }

    return _constructors;
  }

  /// Set the constructors contained in this class to the given [constructors].
  ///
  /// Should only be used for class elements that are not mixin applications.
  void set constructors(List<ConstructorElement> constructors) {
    assert(!isMixinApplication);
    for (ConstructorElement constructor in constructors) {
      (constructor as ConstructorElementImpl).enclosingElement = this;
    }
    this._constructors = constructors;
  }

  @override
  String get documentationComment {
    if (linkedNode != null) {
      var context = enclosingUnit.linkedContext;
      var comment = context.getDocumentationComment(linkedNode);
      return getCommentNodeRawText(comment);
    }
    return super.documentationComment;
  }

  @override
  List<FieldElement> get fields {
    if (_fields != null) return _fields;

    if (linkedNode != null) {
      if (linkedNode is ClassOrMixinDeclaration) {
        _createPropertiesAndAccessors();
        assert(_fields != null);
        return _fields;
      } else {
        _fields = const [];
      }
    }

    return _fields ?? const <FieldElement>[];
  }

  bool get hasBeenInferred {
    if (linkedNode != null) {
      return linkedContext.hasOverrideInferenceDone(linkedNode);
    }
    return _hasBeenInferred;
  }

  void set hasBeenInferred(bool hasBeenInferred) {
    if (linkedNode != null) {
      return linkedContext.setOverrideInferenceDone(linkedNode);
    }
    _hasBeenInferred = hasBeenInferred;
  }

  @override
  bool get hasNonFinalField {
    List<ClassElement> classesToVisit = new List<ClassElement>();
    HashSet<ClassElement> visitedClasses = new HashSet<ClassElement>();
    classesToVisit.add(this);
    while (classesToVisit.isNotEmpty) {
      ClassElement currentElement = classesToVisit.removeAt(0);
      if (visitedClasses.add(currentElement)) {
        // check fields
        for (FieldElement field in currentElement.fields) {
          if (!field.isFinal &&
              !field.isConst &&
              !field.isStatic &&
              !field.isSynthetic) {
            return true;
          }
        }
        // check mixins
        for (InterfaceType mixinType in currentElement.mixins) {
          ClassElement mixinElement = mixinType.element;
          classesToVisit.add(mixinElement);
        }
        // check super
        InterfaceType supertype = currentElement.supertype;
        if (supertype != null) {
          ClassElement superElement = supertype.element;
          if (superElement != null) {
            classesToVisit.add(superElement);
          }
        }
      }
    }
    // not found
    return false;
  }

  /// Return `true` if the class has a concrete `noSuchMethod()` method distinct
  /// from the one declared in class `Object`, as per the Dart Language
  /// Specification (section 10.4).
  bool get hasNoSuchMethod {
    MethodElement method = lookUpConcreteMethod(
        FunctionElement.NO_SUCH_METHOD_METHOD_NAME, library);
    ClassElement definingClass = method?.enclosingElement;
    return definingClass != null && !definingClass.isDartCoreObject;
  }

  @override
  bool get hasReferenceToSuper => hasModifier(Modifier.REFERENCES_SUPER);

  /// Set whether this class references 'super'.
  void set hasReferenceToSuper(bool isReferencedSuper) {
    setModifier(Modifier.REFERENCES_SUPER, isReferencedSuper);
  }

  @override
  bool get hasStaticMember {
    for (MethodElement method in methods) {
      if (method.isStatic) {
        return true;
      }
    }
    for (PropertyAccessorElement accessor in accessors) {
      if (accessor.isStatic) {
        return true;
      }
    }
    return false;
  }

  @override
  List<InterfaceType> get interfaces {
    if (_interfaces != null) {
      return _interfaces;
    }

    if (linkedNode != null) {
      var context = enclosingUnit.linkedContext;
      var implementsClause = context.getImplementsClause(linkedNode);
      if (implementsClause != null) {
        return _interfaces = implementsClause.interfaces
            .map((node) => node.type)
            .whereType<InterfaceType>()
            .where(_isInterfaceTypeInterface)
            .toList();
      } else {
        return _interfaces = const [];
      }
    }
    return _interfaces = const <InterfaceType>[];
  }

  void set interfaces(List<InterfaceType> interfaces) {
    _interfaces = interfaces;
  }

  @override
  bool get isAbstract {
    if (linkedNode != null) {
      return enclosingUnit.linkedContext.isAbstract(linkedNode);
    }
    return hasModifier(Modifier.ABSTRACT);
  }

  /// Set whether this class is abstract.
  void set isAbstract(bool isAbstract) {
    setModifier(Modifier.ABSTRACT, isAbstract);
  }

  @override
  bool get isDartCoreObject => !isMixin && supertype == null;

  @override
  bool get isMixinApplication {
    if (linkedNode != null) {
      return linkedNode is ClassTypeAlias;
    }
    return hasModifier(Modifier.MIXIN_APPLICATION);
  }

  @override
  bool get isOrInheritsProxy =>
      _safeIsOrInheritsProxy(this, new HashSet<ClassElement>());

  @override
  bool get isProxy {
    for (ElementAnnotation annotation in metadata) {
      if (annotation.isProxy) {
        return true;
      }
    }
    return false;
  }

  @override
  bool get isSimplyBounded {
    if (linkedNode != null) {
      return linkedContext.isSimplyBounded(linkedNode);
    }
    return super.isSimplyBounded;
  }

  @override
  bool get isValidMixin {
    if (hasReferenceToSuper) {
      return false;
    }
    if (!supertype.isObject) {
      return false;
    }
    for (ConstructorElement constructor in constructors) {
      if (!constructor.isSynthetic && !constructor.isFactory) {
        return false;
      }
    }
    return true;
  }

  @override
  List<MethodElement> get methods {
    if (_methods != null) {
      return _methods;
    }

    if (linkedNode != null) {
      var context = enclosingUnit.linkedContext;
      var containerRef = reference.getChild('@method');
      return _methods = context
          .getMethods(linkedNode)
          .where((node) => node.propertyKeyword == null)
          .map((node) {
        var name = node.name.name;
        var reference = containerRef.getChild(name);
        if (reference.hasElementFor(node)) {
          return reference.element as MethodElement;
        }
        return MethodElementImpl.forLinkedNode(this, reference, node);
      }).toList();
    }

    return _methods = const <MethodElement>[];
  }

  /// Set the methods contained in this class to the given [methods].
  void set methods(List<MethodElement> methods) {
    for (MethodElement method in methods) {
      (method as MethodElementImpl).enclosingElement = this;
    }
    _methods = methods;
  }

  /// Set whether this class is a mixin application.
  void set mixinApplication(bool isMixinApplication) {
    setModifier(Modifier.MIXIN_APPLICATION, isMixinApplication);
  }

  @override
  List<InterfaceType> get mixins {
    if (linkedMixinInferenceCallback != null) {
      _mixins = linkedMixinInferenceCallback(this);
    }

    if (_mixins != null) {
      return _mixins;
    }

    if (linkedNode != null) {
      var context = enclosingUnit.linkedContext;
      var withClause = context.getWithClause(linkedNode);
      if (withClause != null) {
        return _mixins = withClause.mixinTypes
            .map((node) => node.type)
            .whereType<InterfaceType>()
            .where(_isInterfaceTypeInterface)
            .toList();
      } else {
        return _mixins = const [];
      }
    }
    return _mixins = const <InterfaceType>[];
  }

  void set mixins(List<InterfaceType> mixins) {
    _mixins = mixins;
  }

  @override
  String get name {
    if (linkedNode != null) {
      return reference.name;
    }
    return super.name;
  }

  @override
  int get nameOffset {
    if (linkedNode != null) {
      return enclosingUnit.linkedContext.getNameOffset(linkedNode);
    }
    return super.nameOffset;
  }

  /// Names of methods, getters, setters, and operators that this mixin
  /// declaration super-invokes.  For setters this includes the trailing "=".
  /// The list will be empty if this class is not a mixin declaration.
  List<String> get superInvokedNames => const <String>[];

  @override
  InterfaceType get supertype {
    if (_supertype != null) return _supertype;

    if (linkedNode != null) {
      var context = enclosingUnit.linkedContext;

      var coreTypes = context.bundleContext.elementFactory.coreTypes;
      if (identical(this, coreTypes.objectClass)) {
        return null;
      }

      var type = context.getSuperclass(linkedNode)?.type;
      if (_isInterfaceTypeClass(type)) {
        return _supertype = type;
      }
      return _supertype = this.context.typeProvider.objectType;
    }
    return _supertype;
  }

  void set supertype(InterfaceType supertype) {
    _supertype = supertype;
  }

  @override
  InterfaceType get type {
    if (_type == null) {
      var typeArguments = typeParameters.map((e) => e.type).toList();
      InterfaceTypeImpl type =
          new InterfaceTypeImpl.explicit(this, typeArguments);
      _type = type;
    }
    return _type;
  }

  /// Set the type parameters defined for this class to the given
  /// [typeParameters].
  void set typeParameters(List<TypeParameterElement> typeParameters) {
    for (TypeParameterElement typeParameter in typeParameters) {
      (typeParameter as TypeParameterElementImpl).enclosingElement = this;
    }
    this._typeParameterElements = typeParameters;
  }

  @override
  ConstructorElement get unnamedConstructor {
    for (ConstructorElement element in constructors) {
      String name = element.displayName;
      if (name == null || name.isEmpty) {
        return element;
      }
    }
    return null;
  }

  @override
  void appendTo(StringBuffer buffer) {
    if (isAbstract) {
      buffer.write('abstract ');
    }
    buffer.write('class ');
    String name = displayName;
    if (name == null) {
      buffer.write("{unnamed class}");
    } else {
      buffer.write(name);
    }
    int variableCount = typeParameters.length;
    if (variableCount > 0) {
      buffer.write("<");
      for (int i = 0; i < variableCount; i++) {
        if (i > 0) {
          buffer.write(", ");
        }
        (typeParameters[i] as TypeParameterElementImpl).appendTo(buffer);
      }
      buffer.write(">");
    }
    if (supertype != null && !supertype.isObject) {
      buffer.write(' extends ');
      buffer.write(supertype.displayName);
    }
    if (mixins.isNotEmpty) {
      buffer.write(' with ');
      buffer.write(mixins.map((t) => t.displayName).join(', '));
    }
    if (interfaces.isNotEmpty) {
      buffer.write(' implements ');
      buffer.write(interfaces.map((t) => t.displayName).join(', '));
    }
  }

  @override
  ElementImpl getChild(String identifier) {
    ElementImpl child = super.getChild(identifier);
    if (child != null) {
      return child;
    }
    //
    // The casts in this method are safe because the set methods would have
    // thrown a CCE if any of the elements in the arrays were not of the
    // expected types.
    //
    for (ConstructorElement constructor in constructors) {
      ConstructorElementImpl constructorImpl = constructor;
      if (constructorImpl.identifier == identifier) {
        return constructorImpl;
      }
    }
    for (MethodElement method in methods) {
      MethodElementImpl methodImpl = method;
      if (methodImpl.identifier == identifier) {
        return methodImpl;
      }
    }
    for (TypeParameterElement typeParameter in typeParameters) {
      TypeParameterElementImpl typeParameterImpl = typeParameter;
      if (typeParameterImpl.identifier == identifier) {
        return typeParameterImpl;
      }
    }
    return null;
  }

  @override
  ConstructorElement getNamedConstructor(String name) =>
      getNamedConstructorFromList(name, constructors);

  @override
  void visitChildren(ElementVisitor visitor) {
    super.visitChildren(visitor);
    safelyVisitChildren(constructors, visitor);
    safelyVisitChildren(methods, visitor);
    safelyVisitChildren(typeParameters, visitor);
  }

  /// Compute a list of constructors for this class, which is a mixin
  /// application.  If specified, [visitedClasses] is a list of the other mixin
  /// application classes which have been visited on the way to reaching this
  /// one (this is used to detect circularities).
  List<ConstructorElement> _computeMixinAppConstructors(
      [List<ClassElementImpl> visitedClasses]) {
    // First get the list of constructors of the superclass which need to be
    // forwarded to this class.
    Iterable<ConstructorElement> constructorsToForward;
    if (supertype == null) {
      // Shouldn't ever happen, since the only classes with no supertype are
      // Object and mixins, and they aren't a mixin application. But for
      // safety's sake just assume an empty list.
      assert(false);
      constructorsToForward = <ConstructorElement>[];
    } else if (!supertype.element.isMixinApplication) {
      var library = this.library;
      constructorsToForward = supertype.element.constructors
          .where((constructor) => constructor.isAccessibleIn(library));
    } else {
      if (visitedClasses == null) {
        visitedClasses = <ClassElementImpl>[this];
      } else {
        if (visitedClasses.contains(this)) {
          // Loop in the class hierarchy.  Don't try to forward any
          // constructors.
          return <ConstructorElement>[];
        }
        visitedClasses.add(this);
      }
      try {
        ClassElementImpl superElement = supertype.element;
        constructorsToForward =
            superElement._computeMixinAppConstructors(visitedClasses);
      } finally {
        visitedClasses.removeLast();
      }
    }

    // Figure out the type parameter substitution we need to perform in order
    // to produce constructors for this class.  We want to be robust in the
    // face of errors, so drop any extra type arguments and fill in any missing
    // ones with `dynamic`.
    var superTypeParameters = supertype.typeParameters;
    List<DartType> argumentTypes = new List<DartType>.filled(
        superTypeParameters.length, DynamicTypeImpl.instance);
    for (int i = 0; i < supertype.typeArguments.length; i++) {
      if (i >= argumentTypes.length) {
        break;
      }
      argumentTypes[i] = supertype.typeArguments[i];
    }
    var substitution =
        Substitution.fromPairs(superTypeParameters, argumentTypes);

    // Now create an implicit constructor for every constructor found above,
    // substituting type parameters as appropriate.
    return constructorsToForward
        .map((ConstructorElement superclassConstructor) {
      ConstructorElementImpl implicitConstructor =
          new ConstructorElementImpl(superclassConstructor.name, -1);
      implicitConstructor.isSynthetic = true;
      implicitConstructor.redirectedConstructor = superclassConstructor;
      List<ParameterElement> superParameters = superclassConstructor.parameters;
      int count = superParameters.length;
      if (count > 0) {
        List<ParameterElement> implicitParameters =
            new List<ParameterElement>(count);
        for (int i = 0; i < count; i++) {
          ParameterElement superParameter = superParameters[i];
          ParameterElementImpl implicitParameter;
          if (superParameter is DefaultParameterElementImpl) {
            implicitParameter =
                new DefaultParameterElementImpl(superParameter.name, -1)
                  ..constantInitializer = superParameter.constantInitializer;
          } else {
            implicitParameter =
                new ParameterElementImpl(superParameter.name, -1);
          }
          implicitParameter.isConst = superParameter.isConst;
          implicitParameter.isFinal = superParameter.isFinal;
          // ignore: deprecated_member_use_from_same_package
          implicitParameter.parameterKind = superParameter.parameterKind;
          implicitParameter.isSynthetic = true;
          implicitParameter.type =
              substitution.substituteType(superParameter.type);
          implicitParameters[i] = implicitParameter;
        }
        implicitConstructor.parameters = implicitParameters;
      }
      implicitConstructor.enclosingElement = this;
      return implicitConstructor;
    }).toList(growable: false);
  }

  void _createPropertiesAndAccessors() {
    assert(_accessors == null);
    assert(_fields == null);

    var context = enclosingUnit.linkedContext;
    var accessorList = <PropertyAccessorElement>[];
    var fieldList = <FieldElement>[];

    var fields = context.getFields(linkedNode);
    for (var field in fields) {
      var name = field.name.name;
      var fieldElement = FieldElementImpl.forLinkedNodeFactory(
        this,
        reference.getChild('@field').getChild(name),
        field,
      );
      fieldList.add(fieldElement);

      accessorList.add(fieldElement.getter);
      if (fieldElement.setter != null) {
        accessorList.add(fieldElement.setter);
      }
    }

    var methods = context.getMethods(linkedNode);
    for (var method in methods) {
      var isGetter = method.isGetter;
      var isSetter = method.isSetter;
      if (!isGetter && !isSetter) continue;

      var name = method.name.name;
      var containerRef = isGetter
          ? reference.getChild('@getter')
          : reference.getChild('@setter');

      var accessorElement = PropertyAccessorElementImpl.forLinkedNode(
        this,
        containerRef.getChild(name),
        method,
      );
      accessorList.add(accessorElement);

      var fieldRef = reference.getChild('@field').getChild(name);
      FieldElementImpl field = fieldRef.element;
      if (field == null) {
        field = new FieldElementImpl(name, -1);
        fieldRef.element = field;
        field.enclosingElement = this;
        field.isSynthetic = true;
        field.isFinal = isGetter;
        field.isStatic = accessorElement.isStatic;
        fieldList.add(field);
      } else {
        field.isFinal = false;
      }

      accessorElement.variable = field;
      if (isGetter) {
        field.getter ??= accessorElement;
      } else {
        field.setter ??= accessorElement;
      }
    }

    _accessors = accessorList;
    _fields = fieldList;
  }

  /// Return `true` if the given [type] is an [InterfaceType] that can be used
  /// as a class.
  bool _isInterfaceTypeClass(DartType type) {
    if (type is InterfaceType) {
      var element = type.element;
      return !element.isEnum && !element.isMixin;
    }
    return false;
  }

  /// Return `true` if the given [type] is an [InterfaceType] that can be used
  /// as an interface or a mixin.
  bool _isInterfaceTypeInterface(DartType type) {
    return type is InterfaceType && !type.element.isEnum;
  }

  bool _safeIsOrInheritsProxy(
      ClassElement element, HashSet<ClassElement> visited) {
    if (visited.contains(element)) {
      return false;
    }
    visited.add(element);
    if (element.isProxy) {
      return true;
    } else if (element.supertype != null &&
        _safeIsOrInheritsProxy(element.supertype.element, visited)) {
      return true;
    }
    List<InterfaceType> supertypes = element.interfaces;
    for (int i = 0; i < supertypes.length; i++) {
      if (_safeIsOrInheritsProxy(supertypes[i].element, visited)) {
        return true;
      }
    }
    supertypes = element.mixins;
    for (int i = 0; i < supertypes.length; i++) {
      if (_safeIsOrInheritsProxy(supertypes[i].element, visited)) {
        return true;
      }
    }
    return false;
  }

  static void collectAllSupertypes(List<InterfaceType> supertypes,
      InterfaceType startingType, InterfaceType excludeType) {
    List<InterfaceType> typesToVisit = new List<InterfaceType>();
    List<ClassElement> visitedClasses = new List<ClassElement>();
    typesToVisit.add(startingType);
    while (typesToVisit.isNotEmpty) {
      InterfaceType currentType = typesToVisit.removeAt(0);
      ClassElement currentElement = currentType.element;
      if (!visitedClasses.contains(currentElement)) {
        visitedClasses.add(currentElement);
        if (!identical(currentType, excludeType)) {
          supertypes.add(currentType);
        }
        InterfaceType supertype = currentType.superclass;
        if (supertype != null) {
          typesToVisit.add(supertype);
        }
        for (InterfaceType type in currentType.superclassConstraints) {
          typesToVisit.add(type);
        }
        for (InterfaceType type in currentType.interfaces) {
          typesToVisit.add(type);
        }
        for (InterfaceType type in currentType.mixins) {
          typesToVisit.add(type);
        }
      }
    }
  }

  static ConstructorElement getNamedConstructorFromList(
      String name, List<ConstructorElement> constructors) {
    for (ConstructorElement element in constructors) {
      String elementName = element.name;
      if (elementName != null && elementName == name) {
        return element;
      }
    }
    return null;
  }
}

/// A concrete implementation of a [CompilationUnitElement].
class CompilationUnitElementImpl extends UriReferencedElementImpl
    implements CompilationUnitElement {
  final LinkedUnitContext linkedContext;

  /// The source that corresponds to this compilation unit.
  @override
  Source source;

  @override
  LineInfo lineInfo;

  /// The source of the library containing this compilation unit.
  ///
  /// This is the same as the source of the containing [LibraryElement],
  /// except that it does not require the containing [LibraryElement] to be
  /// computed.
  Source librarySource;

  /// A list containing all of the top-level accessors (getters and setters)
  /// contained in this compilation unit.
  List<PropertyAccessorElement> _accessors;

  /// A list containing all of the enums contained in this compilation unit.
  List<ClassElement> _enums;

  /// A list containing all of the extensions contained in this compilation
  /// unit.
  List<ExtensionElement> _extensions;

  /// A list containing all of the top-level functions contained in this
  /// compilation unit.
  List<FunctionElement> _functions;

  /// A list containing all of the mixins contained in this compilation unit.
  List<ClassElement> _mixins;

  /// A list containing all of the function type aliases contained in this
  /// compilation unit.
  List<FunctionTypeAliasElement> _typeAliases;

  /// A list containing all of the classes contained in this compilation unit.
  List<ClassElement> _types;

  /// A list containing all of the variables contained in this compilation unit.
  List<TopLevelVariableElement> _variables;

  /// Initialize a newly created compilation unit element to have the given
  /// [name].
  CompilationUnitElementImpl()
      : linkedContext = null,
        super(null, -1);

  CompilationUnitElementImpl.forLinkedNode(LibraryElementImpl enclosingLibrary,
      this.linkedContext, Reference reference, CompilationUnit linkedNode)
      : super.forLinkedNode(enclosingLibrary, reference, linkedNode) {
    _nameOffset = -1;
  }

  @override
  List<PropertyAccessorElement> get accessors {
    if (_accessors != null) return _accessors;

    if (linkedNode != null) {
      _createPropertiesAndAccessors(this);
      assert(_accessors != null);
      return _accessors;
    }

    return _accessors ?? const <PropertyAccessorElement>[];
  }

  /// Set the top-level accessors (getters and setters) contained in this
  /// compilation unit to the given [accessors].
  void set accessors(List<PropertyAccessorElement> accessors) {
    for (PropertyAccessorElement accessor in accessors) {
      (accessor as PropertyAccessorElementImpl).enclosingElement = this;
    }
    this._accessors = accessors;
  }

  @override
  int get codeLength {
    if (linkedNode != null) {
      return linkedContext.getCodeLength(linkedNode);
    }
    return super.codeLength;
  }

  @override
  int get codeOffset {
    if (linkedNode != null) {
      return linkedContext.getCodeOffset(linkedNode);
    }
    return super.codeOffset;
  }

  @override
  LibraryElement get enclosingElement =>
      super.enclosingElement as LibraryElement;

  @override
  CompilationUnitElementImpl get enclosingUnit {
    return this;
  }

  @override
  List<ClassElement> get enums {
    if (_enums != null) return _enums;

    if (linkedNode != null) {
      var containerRef = reference.getChild('@enum');
      CompilationUnit linkedNode = this.linkedNode;
      _enums = linkedNode.declarations.whereType<EnumDeclaration>().map((node) {
        var name = node.name.name;
        var reference = containerRef.getChild(name);
        if (reference.hasElementFor(node)) {
          return reference.element as EnumElementImpl;
        }
        return EnumElementImpl.forLinkedNode(this, reference, node);
      }).toList();
    }

    return _enums ??= const <ClassElement>[];
  }

  /// Set the enums contained in this compilation unit to the given [enums].
  void set enums(List<ClassElement> enums) {
    for (ClassElement enumDeclaration in enums) {
      (enumDeclaration as EnumElementImpl).enclosingElement = this;
    }
    this._enums = enums;
  }

  @override
  List<ExtensionElement> get extensions {
    if (_extensions != null) {
      return _extensions;
    }

    if (linkedNode != null) {
      CompilationUnit linkedNode = this.linkedNode;
      var containerRef = reference.getChild('@extension');
      _extensions = <ExtensionElement>[];
      for (var node in linkedNode.declarations) {
        if (node is ExtensionDeclaration) {
          var refName = linkedContext.getExtensionRefName(node);
          var reference = containerRef.getChild(refName);
          if (reference.hasElementFor(node)) {
            _extensions.add(reference.element);
          } else {
            _extensions.add(
              ExtensionElementImpl.forLinkedNode(this, reference, node),
            );
          }
        }
      }
      return _extensions;
    }
    return _extensions ?? const <ExtensionElement>[];
  }

  /// Set the extensions contained in this compilation unit to the given
  /// [extensions].
  void set extensions(List<ExtensionElement> extensions) {
    for (ExtensionElement extension in extensions) {
      (extension as ExtensionElementImpl).enclosingElement = this;
    }
    this._extensions = extensions;
  }

  @override
  List<FunctionElement> get functions {
    if (_functions != null) return _functions;

    if (linkedNode != null) {
      CompilationUnit linkedNode = this.linkedNode;
      var containerRef = reference.getChild('@function');
      return _functions = linkedNode.declarations
          .whereType<FunctionDeclaration>()
          .where((node) => !node.isGetter && !node.isSetter)
          .map((node) {
        var name = node.name.name;
        var reference = containerRef.getChild(name);
        if (reference.hasElementFor(node)) {
          return reference.element as FunctionElementImpl;
        }
        return FunctionElementImpl.forLinkedNode(this, reference, node);
      }).toList();
    }
    return _functions ?? const <FunctionElement>[];
  }

  /// Set the top-level functions contained in this compilation unit to the
  ///  given[functions].
  void set functions(List<FunctionElement> functions) {
    for (FunctionElement function in functions) {
      (function as FunctionElementImpl).enclosingElement = this;
    }
    this._functions = functions;
  }

  @override
  List<FunctionTypeAliasElement> get functionTypeAliases {
    if (_typeAliases != null) return _typeAliases;

    if (linkedNode != null) {
      CompilationUnit linkedNode = this.linkedNode;
      var containerRef = reference.getChild('@typeAlias');
      return _typeAliases = linkedNode.declarations.where((node) {
        return node is FunctionTypeAlias || node is GenericTypeAlias;
      }).map((node) {
        String name;
        if (node is FunctionTypeAlias) {
          name = node.name.name;
        } else {
          name = (node as GenericTypeAlias).name.name;
        }

        var reference = containerRef.getChild(name);
        if (reference.hasElementFor(node)) {
          return reference.element as GenericTypeAliasElementImpl;
        }
        return GenericTypeAliasElementImpl.forLinkedNode(this, reference, node);
      }).toList();
    }

    return _typeAliases ?? const <FunctionTypeAliasElement>[];
  }

  @override
  int get hashCode => source.hashCode;

  @override
  bool get hasLoadLibraryFunction {
    List<FunctionElement> functions = this.functions;
    for (int i = 0; i < functions.length; i++) {
      if (functions[i].name == FunctionElement.LOAD_LIBRARY_NAME) {
        return true;
      }
    }
    return false;
  }

  @override
  String get identifier => '${source.uri}';

  @override
  ElementKind get kind => ElementKind.COMPILATION_UNIT;

  @override
  List<ClassElement> get mixins {
    if (_mixins != null) return _mixins;

    if (linkedNode != null) {
      CompilationUnit linkedNode = this.linkedNode;
      var containerRef = reference.getChild('@mixin');
      var declarations = linkedNode.declarations;
      return _mixins = declarations.whereType<MixinDeclaration>().map((node) {
        var name = node.name.name;
        var reference = containerRef.getChild(name);
        if (reference.hasElementFor(node)) {
          return reference.element as MixinElementImpl;
        }
        return MixinElementImpl.forLinkedNode(this, reference, node);
      }).toList();
    }

    return _mixins ?? const <ClassElement>[];
  }

  /// Set the mixins contained in this compilation unit to the given [mixins].
  void set mixins(List<ClassElement> mixins) {
    for (MixinElementImpl type in mixins) {
      type.enclosingElement = this;
    }
    this._mixins = mixins;
  }

  @override
  List<TopLevelVariableElement> get topLevelVariables {
    if (linkedNode != null) {
      if (_variables != null) return _variables;
      _createPropertiesAndAccessors(this);
      assert(_variables != null);
      return _variables;
    }
    return _variables ?? const <TopLevelVariableElement>[];
  }

  /// Set the top-level variables contained in this compilation unit to the
  ///  given[variables].
  void set topLevelVariables(List<TopLevelVariableElement> variables) {
    for (TopLevelVariableElement field in variables) {
      (field as TopLevelVariableElementImpl).enclosingElement = this;
    }
    this._variables = variables;
  }

  /// Set the function type aliases contained in this compilation unit to the
  /// given [typeAliases].
  void set typeAliases(List<FunctionTypeAliasElement> typeAliases) {
    for (FunctionTypeAliasElement typeAlias in typeAliases) {
      (typeAlias as ElementImpl).enclosingElement = this;
    }
    this._typeAliases = typeAliases;
  }

  @override
  TypeParameterizedElementMixin get typeParameterContext => null;

  @override
  List<ClassElement> get types {
    if (_types != null) return _types;

    if (linkedNode != null) {
      CompilationUnit linkedNode = this.linkedNode;
      var containerRef = reference.getChild('@class');
      _types = <ClassElement>[];
      for (var node in linkedNode.declarations) {
        String name;
        if (node is ClassDeclaration) {
          name = node.name.name;
        } else if (node is ClassTypeAlias) {
          name = node.name.name;
        } else {
          continue;
        }
        var reference = containerRef.getChild(name);
        if (reference.hasElementFor(node)) {
          _types.add(reference.element);
        } else {
          _types.add(
            ClassElementImpl.forLinkedNode(this, reference, node),
          );
        }
      }
      return _types;
    }

    return _types ?? const <ClassElement>[];
  }

  /// Set the types contained in this compilation unit to the given [types].
  void set types(List<ClassElement> types) {
    for (ClassElement type in types) {
      // Another implementation of ClassElement is _DeferredClassElement,
      // which is used to resynthesize classes lazily. We cannot cast it
      // to ClassElementImpl, and it already can provide correct values of the
      // 'enclosingElement' property.
      if (type is ClassElementImpl) {
        type.enclosingElement = this;
      }
    }
    this._types = types;
  }

  @override
  bool operator ==(Object object) =>
      object is CompilationUnitElementImpl && source == object.source;

  @override
  T accept<T>(ElementVisitor<T> visitor) =>
      visitor.visitCompilationUnitElement(this);

  @override
  void appendTo(StringBuffer buffer) {
    if (source == null) {
      buffer.write("{compilation unit}");
    } else {
      buffer.write(source.fullName);
    }
  }

  @override
  ElementImpl getChild(String identifier) {
    //
    // The casts in this method are safe because the set methods would have
    // thrown a CCE if any of the elements in the arrays were not of the
    // expected types.
    //
    for (PropertyAccessorElement accessor in accessors) {
      PropertyAccessorElementImpl accessorImpl = accessor;
      if (accessorImpl.identifier == identifier) {
        return accessorImpl;
      }
    }
    for (TopLevelVariableElement variable in topLevelVariables) {
      TopLevelVariableElementImpl variableImpl = variable;
      if (variableImpl.identifier == identifier) {
        return variableImpl;
      }
    }
    for (FunctionElement function in functions) {
      FunctionElementImpl functionImpl = function;
      if (functionImpl.identifier == identifier) {
        return functionImpl;
      }
    }
    for (GenericTypeAliasElementImpl typeAlias in functionTypeAliases) {
      if (typeAlias.identifier == identifier) {
        return typeAlias;
      }
    }
    for (ClassElement type in types) {
      ClassElementImpl typeImpl = type;
      if (typeImpl.name == identifier) {
        return typeImpl;
      }
    }
    for (ClassElement type in enums) {
      EnumElementImpl typeImpl = type;
      if (typeImpl.identifier == identifier) {
        return typeImpl;
      }
    }
    return null;
  }

  @override
  ClassElement getEnum(String enumName) {
    for (ClassElement enumDeclaration in enums) {
      if (enumDeclaration.name == enumName) {
        return enumDeclaration;
      }
    }
    return null;
  }

  @override
  ClassElement getType(String className) {
    return getTypeFromTypes(className, types);
  }

  /// Replace the given [from] top-level variable with [to] in this compilation
  /// unit.
  void replaceTopLevelVariable(
      TopLevelVariableElement from, TopLevelVariableElement to) {
    int index = _variables.indexOf(from);
    _variables[index] = to;
  }

  @override
  void visitChildren(ElementVisitor visitor) {
    super.visitChildren(visitor);
    safelyVisitChildren(accessors, visitor);
    safelyVisitChildren(enums, visitor);
    safelyVisitChildren(extensions, visitor);
    safelyVisitChildren(functions, visitor);
    safelyVisitChildren(functionTypeAliases, visitor);
    safelyVisitChildren(mixins, visitor);
    safelyVisitChildren(types, visitor);
    safelyVisitChildren(topLevelVariables, visitor);
  }

  static ClassElement getTypeFromTypes(
      String className, List<ClassElement> types) {
    for (ClassElement type in types) {
      if (type.name == className) {
        return type;
      }
    }
    return null;
  }

  static void _createPropertiesAndAccessors(CompilationUnitElementImpl unit) {
    if (unit._variables != null) return;
    assert(unit._accessors == null);

    var accessorMap =
        <CompilationUnitElementImpl, List<PropertyAccessorElement>>{};
    var variableMap =
        <CompilationUnitElementImpl, List<TopLevelVariableElement>>{};

    var units = unit.library.units;
    for (CompilationUnitElementImpl unit in units) {
      var context = unit.linkedContext;

      var accessorList = <PropertyAccessorElement>[];
      accessorMap[unit] = accessorList;

      var variableList = <TopLevelVariableElement>[];
      variableMap[unit] = variableList;

      var unitNode = unit.linkedContext.unit_withDeclarations;
      var unitDeclarations = unitNode.declarations;

      var variables = context.topLevelVariables(unitNode);
      for (var variable in variables) {
        var name = variable.name.name;
        var reference = unit.reference.getChild('@variable').getChild(name);
        var variableElement = TopLevelVariableElementImpl.forLinkedNodeFactory(
          unit,
          reference,
          variable,
        );
        variableList.add(variableElement);

        accessorList.add(variableElement.getter);
        if (variableElement.setter != null) {
          accessorList.add(variableElement.setter);
        }
      }

      for (var node in unitDeclarations) {
        if (node is FunctionDeclaration) {
          var isGetter = node.isGetter;
          var isSetter = node.isSetter;
          if (!isGetter && !isSetter) continue;

          var name = node.name.name;
          var containerRef = isGetter
              ? unit.reference.getChild('@getter')
              : unit.reference.getChild('@setter');

          var accessorElement = PropertyAccessorElementImpl.forLinkedNode(
            unit,
            containerRef.getChild(name),
            node,
          );
          accessorList.add(accessorElement);

          var fieldRef = unit.reference.getChild('@field').getChild(name);
          TopLevelVariableElementImpl field = fieldRef.element;
          if (field == null) {
            field = new TopLevelVariableElementImpl(name, -1);
            fieldRef.element = field;
            field.enclosingElement = unit;
            field.isSynthetic = true;
            field.isFinal = isGetter;
            variableList.add(field);
          } else {
            field.isFinal = false;
          }

          accessorElement.variable = field;
          if (isGetter) {
            field.getter = accessorElement;
          } else {
            field.setter = accessorElement;
          }
        }
      }
    }

    for (CompilationUnitElementImpl unit in units) {
      unit._accessors = accessorMap[unit];
      unit._variables = variableMap[unit];
    }
  }
}

/// A [FieldElement] for a 'const' or 'final' field that has an initializer.
///
/// TODO(paulberry): we should rename this class to reflect the fact that it's
/// used for both const and final fields.  However, we shouldn't do so until
/// we've created an API for reading the values of constants; until that API is
/// available, clients are likely to read constant values by casting to
/// ConstFieldElementImpl, so it would be a breaking change to rename this
/// class.
class ConstFieldElementImpl extends FieldElementImpl with ConstVariableElement {
  /// Initialize a newly created synthetic field element to have the given
  /// [name] and [offset].
  ConstFieldElementImpl(String name, int offset) : super(name, offset);

  ConstFieldElementImpl.forLinkedNode(
      ElementImpl enclosing, Reference reference, AstNode linkedNode)
      : super.forLinkedNode(enclosing, reference, linkedNode);

  /// Initialize a newly created field element to have the given [name].
  ConstFieldElementImpl.forNode(Identifier name) : super.forNode(name);
}

/// A field element representing an enum constant.
class ConstFieldElementImpl_EnumValue extends ConstFieldElementImpl_ofEnum {
  final int _index;

  ConstFieldElementImpl_EnumValue(EnumElementImpl enumElement, this._index)
      : super(enumElement);

  ConstFieldElementImpl_EnumValue.forLinkedNode(EnumElementImpl enumElement,
      Reference reference, AstNode linkedNode, this._index)
      : super.forLinkedNode(enumElement, reference, linkedNode);

  @override
  Expression get constantInitializer => null;

  @override
  String get documentationComment {
    if (linkedNode != null) {
      var context = enclosingUnit.linkedContext;
      var comment = context.getDocumentationComment(linkedNode);
      return getCommentNodeRawText(comment);
    }
    return super.documentationComment;
  }

  @override
  EvaluationResultImpl get evaluationResult {
    if (_evaluationResult == null) {
      Map<String, DartObjectImpl> fieldMap = <String, DartObjectImpl>{
        name: new DartObjectImpl(
            context.typeProvider.intType, new IntState(_index))
      };
      DartObjectImpl value =
          new DartObjectImpl(type, new GenericState(fieldMap));
      _evaluationResult = new EvaluationResultImpl(value);
    }
    return _evaluationResult;
  }

  @override
  String get name {
    if (linkedNode != null) {
      return reference.name;
    }
    return super.name;
  }

  @override
  int get nameOffset {
    if (linkedNode != null) {
      return enclosingUnit.linkedContext.getNameOffset(linkedNode);
    }
    return super.nameOffset;
  }

  @override
  InterfaceType get type => _enum.thisType;
}

/// The synthetic `values` field of an enum.
class ConstFieldElementImpl_EnumValues extends ConstFieldElementImpl_ofEnum {
  ConstFieldElementImpl_EnumValues(EnumElementImpl enumElement)
      : super(enumElement) {
    isSynthetic = true;
  }

  @override
  EvaluationResultImpl get evaluationResult {
    if (_evaluationResult == null) {
      List<DartObjectImpl> constantValues = <DartObjectImpl>[];
      for (FieldElement field in _enum.fields) {
        if (field is ConstFieldElementImpl_EnumValue) {
          constantValues.add(field.evaluationResult.value);
        }
      }
      _evaluationResult = new EvaluationResultImpl(
          new DartObjectImpl(type, new ListState(constantValues)));
    }
    return _evaluationResult;
  }

  @override
  String get name => 'values';

  @override
  InterfaceType get type {
    if (_type == null) {
      return _type = context.typeProvider.listType2(_enum.thisType);
    }
    return _type;
  }
}

/// An abstract constant field of an enum.
abstract class ConstFieldElementImpl_ofEnum extends ConstFieldElementImpl {
  final EnumElementImpl _enum;

  ConstFieldElementImpl_ofEnum(this._enum) : super(null, -1) {
    enclosingElement = _enum;
  }

  ConstFieldElementImpl_ofEnum.forLinkedNode(
      this._enum, Reference reference, AstNode linkedNode)
      : super.forLinkedNode(_enum, reference, linkedNode);

  @override
  void set evaluationResult(_) {
    assert(false);
  }

  @override
  bool get isConst => true;

  @override
  void set isConst(bool isConst) {
    assert(false);
  }

  @override
  bool get isConstantEvaluated => true;

  @override
  void set isFinal(bool isFinal) {
    assert(false);
  }

  @override
  bool get isStatic => true;

  @override
  void set isStatic(bool isStatic) {
    assert(false);
  }

  void set type(DartType type) {
    assert(false);
  }
}

/// A [LocalVariableElement] for a local 'const' variable that has an
/// initializer.
class ConstLocalVariableElementImpl extends LocalVariableElementImpl
    with ConstVariableElement {
  /// Initialize a newly created local variable element to have the given [name]
  /// and [offset].
  ConstLocalVariableElementImpl(String name, int offset) : super(name, offset);

  /// Initialize a newly created local variable element to have the given
  /// [name].
  ConstLocalVariableElementImpl.forNode(Identifier name) : super.forNode(name);
}

/// A concrete implementation of a [ConstructorElement].
class ConstructorElementImpl extends ExecutableElementImpl
    implements ConstructorElement {
  /// The constructor to which this constructor is redirecting.
  ConstructorElement _redirectedConstructor;

  /// The initializers for this constructor (used for evaluating constant
  /// instance creation expressions).
  List<ConstructorInitializer> _constantInitializers;

  /// The offset of the `.` before this constructor name or `null` if not named.
  int _periodOffset;

  /// Return the offset of the character immediately following the last
  /// character of this constructor's name, or `null` if not named.
  int _nameEnd;

  /// For every constructor we initially set this flag to `true`, and then
  /// set it to `false` during computing constant values if we detect that it
  /// is a part of a cycle.
  bool _isCycleFree = true;

  @override
  bool isConstantEvaluated = false;

  /// Initialize a newly created constructor element to have the given [name]
  /// and [offset].
  ConstructorElementImpl(String name, int offset) : super(name, offset);

  ConstructorElementImpl.forLinkedNode(ClassElementImpl enclosingClass,
      Reference reference, ConstructorDeclaration linkedNode)
      : super.forLinkedNode(enclosingClass, reference, linkedNode);

  /// Initialize a newly created constructor element to have the given [name].
  ConstructorElementImpl.forNode(Identifier name) : super.forNode(name);

  /// Return the constant initializers for this element, which will be empty if
  /// there are no initializers, or `null` if there was an error in the source.
  List<ConstructorInitializer> get constantInitializers {
    if (_constantInitializers != null) return _constantInitializers;

    if (linkedNode != null) {
      return _constantInitializers = linkedContext.getConstructorInitializers(
        linkedNode,
      );
    }

    return _constantInitializers;
  }

  void set constantInitializers(
      List<ConstructorInitializer> constantInitializers) {
    _constantInitializers = constantInitializers;
  }

  @override
  String get displayName {
    if (linkedNode != null) {
      return reference.name;
    }
    return super.displayName;
  }

  @override
  ClassElementImpl get enclosingElement =>
      super.enclosingElement as ClassElementImpl;

  /// Set whether this constructor represents a factory method.
  void set factory(bool isFactory) {
    setModifier(Modifier.FACTORY, isFactory);
  }

  @override
  bool get isConst {
    if (linkedNode != null) {
      ConstructorDeclaration linkedNode = this.linkedNode;
      return linkedNode.constKeyword != null;
    }
    return hasModifier(Modifier.CONST);
  }

  /// Set whether this constructor represents a 'const' constructor.
  void set isConst(bool isConst) {
    setModifier(Modifier.CONST, isConst);
  }

  bool get isCycleFree {
    return _isCycleFree;
  }

  void set isCycleFree(bool isCycleFree) {
    // This property is updated in ConstantEvaluationEngine even for
    // resynthesized constructors, so we don't have the usual assert here.
    _isCycleFree = isCycleFree;
  }

  @override
  bool get isDefaultConstructor {
    // unnamed
    String name = this.name;
    if (name != null && name.isNotEmpty) {
      return false;
    }
    // no required parameters
    for (ParameterElement parameter in parameters) {
      if (parameter.isNotOptional) {
        return false;
      }
    }
    // OK, can be used as default constructor
    return true;
  }

  @override
  bool get isFactory {
    if (linkedNode != null) {
      ConstructorDeclaration linkedNode = this.linkedNode;
      return linkedNode.factoryKeyword != null;
    }
    return hasModifier(Modifier.FACTORY);
  }

  @override
  bool get isStatic => false;

  @override
  ElementKind get kind => ElementKind.CONSTRUCTOR;

  @override
  String get name {
    if (linkedNode != null) {
      return reference.name;
    }
    return super.name;
  }

  @override
  int get nameEnd {
    if (linkedNode != null) {
      var node = linkedNode as ConstructorDeclaration;
      if (node.name != null) {
        return node.name.end;
      } else {
        return node.returnType.end;
      }
    }

    return _nameEnd;
  }

  void set nameEnd(int nameEnd) {
    _nameEnd = nameEnd;
  }

  @override
  int get periodOffset {
    if (linkedNode != null) {
      var node = linkedNode as ConstructorDeclaration;
      return node.period?.offset;
    }

    return _periodOffset;
  }

  void set periodOffset(int periodOffset) {
    _periodOffset = periodOffset;
  }

  @override
  ConstructorElement get redirectedConstructor {
    if (_redirectedConstructor != null) return _redirectedConstructor;

    if (linkedNode != null) {
      var context = enclosingUnit.linkedContext;
      if (isFactory) {
        var node = context.getConstructorRedirected(linkedNode);
        return _redirectedConstructor = node?.staticElement;
      } else {
        var initializers = context.getConstructorInitializers(linkedNode);
        for (var initializer in initializers) {
          if (initializer is RedirectingConstructorInvocation) {
            return _redirectedConstructor = initializer.staticElement;
          }
        }
      }
      return null;
    }

    return _redirectedConstructor;
  }

  void set redirectedConstructor(ConstructorElement redirectedConstructor) {
    _redirectedConstructor = redirectedConstructor;
  }

  @override
  DartType get returnType {
    if (_returnType != null) return _returnType;

    InterfaceTypeImpl classThisType = enclosingElement.thisType;
    return _returnType = InterfaceTypeImpl.explicit(
      classThisType.element,
      classThisType.typeArguments,
      nullabilitySuffix: classThisType.nullabilitySuffix,
    );
  }

  void set returnType(DartType returnType) {
    assert(false);
  }

  @override
  FunctionType get type {
    // TODO(scheglov) Remove "element" in the breaking changes branch.
    return _type ??= FunctionTypeImpl.synthetic(
      returnType,
      typeParameters,
      parameters,
      element: this,
      nullabilitySuffix: _noneOrStarSuffix,
    );
  }

  void set type(FunctionType type) {
    assert(false);
  }

  @override
  T accept<T>(ElementVisitor<T> visitor) =>
      visitor.visitConstructorElement(this);

  @override
  void appendTo(StringBuffer buffer) {
    String name;
    String constructorName = displayName;
    if (enclosingElement == null) {
      String message;
      if (constructorName != null && constructorName.isNotEmpty) {
        message =
            'Found constructor element named $constructorName with no enclosing element';
      } else {
        message = 'Found unnamed constructor element with no enclosing element';
      }
      AnalysisEngine.instance.logger.logError(message);
      name = '<unknown class>';
    } else {
      name = enclosingElement.displayName;
    }
    if (constructorName != null && constructorName.isNotEmpty) {
      name = '$name.$constructorName';
    }
    appendToWithName(buffer, name);
  }

  /// Ensures that dependencies of this constructor, such as default values
  /// of formal parameters, are evaluated.
  void computeConstantDependencies() {
    if (!isConstantEvaluated) {
      AnalysisOptionsImpl analysisOptions = context.analysisOptions;
      computeConstants(context.typeProvider, context.typeSystem,
          context.declaredVariables, [this], analysisOptions.experimentStatus);
    }
  }
}

/// A [TopLevelVariableElement] for a top-level 'const' variable that has an
/// initializer.
class ConstTopLevelVariableElementImpl extends TopLevelVariableElementImpl
    with ConstVariableElement {
  /// Initialize a newly created synthetic top-level variable element to have
  /// the given [name] and [offset].
  ConstTopLevelVariableElementImpl(String name, int offset)
      : super(name, offset);

  ConstTopLevelVariableElementImpl.forLinkedNode(
      ElementImpl enclosing, Reference reference, AstNode linkedNode)
      : super.forLinkedNode(enclosing, reference, linkedNode);

  /// Initialize a newly created top-level variable element to have the given
  /// [name].
  ConstTopLevelVariableElementImpl.forNode(Identifier name)
      : super.forNode(name);
}

/// Mixin used by elements that represent constant variables and have
/// initializers.
///
/// Note that in correct Dart code, all constant variables must have
/// initializers.  However, analyzer also needs to handle incorrect Dart code,
/// in which case there might be some constant variables that lack initializers.
/// This interface is only used for constant variables that have initializers.
///
/// This class is not intended to be part of the public API for analyzer.
mixin ConstVariableElement implements ElementImpl, ConstantEvaluationTarget {
  /// If this element represents a constant variable, and it has an initializer,
  /// a copy of the initializer for the constant.  Otherwise `null`.
  ///
  /// Note that in correct Dart code, all constant variables must have
  /// initializers.  However, analyzer also needs to handle incorrect Dart code,
  /// in which case there might be some constant variables that lack
  /// initializers.
  Expression _constantInitializer;

  EvaluationResultImpl _evaluationResult;

  Expression get constantInitializer {
    if (_constantInitializer != null) return _constantInitializer;

    if (linkedNode != null) {
      var context = enclosingUnit.linkedContext;
      return _constantInitializer = context.readInitializer(linkedNode);
    }

    return _constantInitializer;
  }

  void set constantInitializer(Expression constantInitializer) {
    _constantInitializer = constantInitializer;
  }

  EvaluationResultImpl get evaluationResult => _evaluationResult;

  void set evaluationResult(EvaluationResultImpl evaluationResult) {
    _evaluationResult = evaluationResult;
  }

  @override
  bool get isConstantEvaluated => _evaluationResult != null;

  /// Return a representation of the value of this variable, forcing the value
  /// to be computed if it had not previously been computed, or `null` if either
  /// this variable was not declared with the 'const' modifier or if the value
  /// of this variable could not be computed because of errors.
  DartObject computeConstantValue() {
    if (evaluationResult == null) {
      AnalysisOptionsImpl analysisOptions = context.analysisOptions;
      computeConstants(context.typeProvider, context.typeSystem,
          context.declaredVariables, [this], analysisOptions.experimentStatus);
    }
    return evaluationResult?.value;
  }
}

/// A [FieldFormalParameterElementImpl] for parameters that have an initializer.
class DefaultFieldFormalParameterElementImpl
    extends FieldFormalParameterElementImpl with ConstVariableElement {
  /// Initialize a newly created parameter element to have the given [name] and
  /// [nameOffset].
  DefaultFieldFormalParameterElementImpl(String name, int nameOffset)
      : super(name, nameOffset);

  DefaultFieldFormalParameterElementImpl.forLinkedNode(
      ElementImpl enclosing, Reference reference, AstNode linkedNode)
      : super.forLinkedNode(enclosing, reference, linkedNode);

  /// Initialize a newly created parameter element to have the given [name].
  DefaultFieldFormalParameterElementImpl.forNode(Identifier name)
      : super.forNode(name);
}

/// A [ParameterElement] for parameters that have an initializer.
class DefaultParameterElementImpl extends ParameterElementImpl
    with ConstVariableElement {
  /// Initialize a newly created parameter element to have the given [name] and
  /// [nameOffset].
  DefaultParameterElementImpl(String name, int nameOffset)
      : super(name, nameOffset);

  DefaultParameterElementImpl.forLinkedNode(
      ElementImpl enclosing, Reference reference, AstNode linkedNode)
      : super.forLinkedNode(enclosing, reference, linkedNode);

  /// Initialize a newly created parameter element to have the given [name].
  DefaultParameterElementImpl.forNode(Identifier name) : super.forNode(name);
}

/// The synthetic element representing the declaration of the type `dynamic`.
class DynamicElementImpl extends ElementImpl implements TypeDefiningElement {
  /// Return the unique instance of this class.
  static DynamicElementImpl get instance =>
      DynamicTypeImpl.instance.element as DynamicElementImpl;

  /// Initialize a newly created instance of this class. Instances of this class
  /// should <b>not</b> be created except as part of creating the type
  /// associated with this element. The single instance of this class should be
  /// accessed through the method [instance].
  DynamicElementImpl() : super(Keyword.DYNAMIC.lexeme, -1) {
    setModifier(Modifier.SYNTHETIC, true);
  }

  @override
  ElementKind get kind => ElementKind.DYNAMIC;

  @override
  DartType get type => DynamicTypeImpl.instance;

  @override
  T accept<T>(ElementVisitor<T> visitor) => null;
}

/// A concrete implementation of an [ElementAnnotation].
class ElementAnnotationImpl implements ElementAnnotation {
  /// The name of the top-level variable used to mark that a function always
  /// throws, for dead code purposes.
  static String _ALWAYS_THROWS_VARIABLE_NAME = "alwaysThrows";

  /// The name of the class used to mark an element as being deprecated.
  static String _DEPRECATED_CLASS_NAME = "Deprecated";

  /// The name of the top-level variable used to mark an element as being
  /// deprecated.
  static String _DEPRECATED_VARIABLE_NAME = "deprecated";

  /// The name of the top-level variable used to mark a method as being a
  /// factory.
  static String _FACTORY_VARIABLE_NAME = "factory";

  /// The name of the top-level variable used to mark a class and its subclasses
  /// as being immutable.
  static String _IMMUTABLE_VARIABLE_NAME = "immutable";

  /// The name of the top-level variable used to mark a constructor as being
  /// literal.
  static String _LITERAL_VARIABLE_NAME = "literal";

  /// The name of the top-level variable used to mark a type as having
  /// "optional" type arguments.
  static String _OPTIONAL_TYPE_ARGS_VARIABLE_NAME = "optionalTypeArgs";

  /// The name of the top-level variable used to mark a function as running
  /// a single test.
  static String _IS_TEST_VARIABLE_NAME = "isTest";

  /// The name of the top-level variable used to mark a function as running
  /// a test group.
  static String _IS_TEST_GROUP_VARIABLE_NAME = "isTestGroup";

  /// The name of the class used to JS annotate an element.
  static String _JS_CLASS_NAME = "JS";

  /// The name of `js` library, used to define JS annotations.
  static String _JS_LIB_NAME = "js";

  /// The name of `meta` library, used to define analysis annotations.
  static String _META_LIB_NAME = "meta";

  /// The name of the top-level variable used to mark a method as requiring
  /// overriders to call super.
  static String _MUST_CALL_SUPER_VARIABLE_NAME = "mustCallSuper";

  /// The name of `angular.meta` library, used to define angular analysis
  /// annotations.
  static String _NG_META_LIB_NAME = "angular.meta";

  /// The name of the top-level variable used to mark a member as being nonVirtual.
  static String _NON_VIRTUAL_VARIABLE_NAME = "nonVirtual";

  /// The name of the top-level variable used to mark a method as being expected
  /// to override an inherited method.
  static String _OVERRIDE_VARIABLE_NAME = "override";

  /// The name of the top-level variable used to mark a method as being
  /// protected.
  static String _PROTECTED_VARIABLE_NAME = "protected";

  /// The name of the top-level variable used to mark a class as implementing a
  /// proxy object.
  static String PROXY_VARIABLE_NAME = "proxy";

  /// The name of the class used to mark a parameter as being required.
  static String _REQUIRED_CLASS_NAME = "Required";

  /// The name of the top-level variable used to mark a parameter as being
  /// required.
  static String _REQUIRED_VARIABLE_NAME = "required";

  /// The name of the top-level variable used to mark a class as being sealed.
  static String _SEALED_VARIABLE_NAME = "sealed";

  /// The name of the top-level variable used to mark a method as being
  /// visible for templates.
  static String _VISIBLE_FOR_TEMPLATE_VARIABLE_NAME = "visibleForTemplate";

  /// The name of the top-level variable used to mark a method as being
  /// visible for testing.
  static String _VISIBLE_FOR_TESTING_VARIABLE_NAME = "visibleForTesting";

  /// The element representing the field, variable, or constructor being used as
  /// an annotation.
  Element element;

  /// The compilation unit in which this annotation appears.
  CompilationUnitElementImpl compilationUnit;

  /// The AST of the annotation itself, cloned from the resolved AST for the
  /// source code.
  Annotation annotationAst;

  /// The result of evaluating this annotation as a compile-time constant
  /// expression, or `null` if the compilation unit containing the variable has
  /// not been resolved.
  EvaluationResultImpl evaluationResult;

  /// Initialize a newly created annotation. The given [compilationUnit] is the
  /// compilation unit in which the annotation appears.
  ElementAnnotationImpl(this.compilationUnit);

  @override
  List<AnalysisError> get constantEvaluationErrors =>
      evaluationResult?.errors ?? const <AnalysisError>[];

  @override
  DartObject get constantValue => evaluationResult?.value;

  @override
  AnalysisContext get context => compilationUnit.library.context;

  @override
  bool get isAlwaysThrows =>
      element is PropertyAccessorElement &&
      element.name == _ALWAYS_THROWS_VARIABLE_NAME &&
      element.library?.name == _META_LIB_NAME;

  @override
  bool get isConstantEvaluated => evaluationResult != null;

  @override
  bool get isDeprecated {
    if (element?.library?.isDartCore == true) {
      if (element is ConstructorElement) {
        return element.enclosingElement.name == _DEPRECATED_CLASS_NAME;
      } else if (element is PropertyAccessorElement) {
        return element.name == _DEPRECATED_VARIABLE_NAME;
      }
    }
    return false;
  }

  @override
  bool get isFactory =>
      element is PropertyAccessorElement &&
      element.name == _FACTORY_VARIABLE_NAME &&
      element.library?.name == _META_LIB_NAME;

  @override
  bool get isImmutable =>
      element is PropertyAccessorElement &&
      element.name == _IMMUTABLE_VARIABLE_NAME &&
      element.library?.name == _META_LIB_NAME;

  @override
  bool get isIsTest =>
      element is PropertyAccessorElement &&
      element.name == _IS_TEST_VARIABLE_NAME &&
      element.library?.name == _META_LIB_NAME;

  @override
  bool get isIsTestGroup =>
      element is PropertyAccessorElement &&
      element.name == _IS_TEST_GROUP_VARIABLE_NAME &&
      element.library?.name == _META_LIB_NAME;

  @override
  bool get isJS =>
      element is ConstructorElement &&
      element.enclosingElement.name == _JS_CLASS_NAME &&
      element.library?.name == _JS_LIB_NAME;

  @override
  bool get isLiteral =>
      element is PropertyAccessorElement &&
      element.name == _LITERAL_VARIABLE_NAME &&
      element.library?.name == _META_LIB_NAME;

  @override
  bool get isMustCallSuper =>
      element is PropertyAccessorElement &&
      element.name == _MUST_CALL_SUPER_VARIABLE_NAME &&
      element.library?.name == _META_LIB_NAME;

  @override
  bool get isNonVirtual =>
      element is PropertyAccessorElement &&
      element.name == _NON_VIRTUAL_VARIABLE_NAME &&
      element.library?.name == _META_LIB_NAME;

  @override
  bool get isOptionalTypeArgs =>
      element is PropertyAccessorElement &&
      element.name == _OPTIONAL_TYPE_ARGS_VARIABLE_NAME &&
      element.library?.name == _META_LIB_NAME;

  @override
  bool get isOverride =>
      element is PropertyAccessorElement &&
      element.name == _OVERRIDE_VARIABLE_NAME &&
      element.library?.isDartCore == true;

  @override
  bool get isProtected =>
      element is PropertyAccessorElement &&
      element.name == _PROTECTED_VARIABLE_NAME &&
      element.library?.name == _META_LIB_NAME;

  @override
  bool get isProxy =>
      element is PropertyAccessorElement &&
      element.name == PROXY_VARIABLE_NAME &&
      element.library?.isDartCore == true;

  @override
  bool get isRequired =>
      element is ConstructorElement &&
          element.enclosingElement.name == _REQUIRED_CLASS_NAME &&
          element.library?.name == _META_LIB_NAME ||
      element is PropertyAccessorElement &&
          element.name == _REQUIRED_VARIABLE_NAME &&
          element.library?.name == _META_LIB_NAME;

  @override
  bool get isSealed =>
      element is PropertyAccessorElement &&
      element.name == _SEALED_VARIABLE_NAME &&
      element.library?.name == _META_LIB_NAME;

  @override
  bool get isVisibleForTemplate =>
      element is PropertyAccessorElement &&
      element.name == _VISIBLE_FOR_TEMPLATE_VARIABLE_NAME &&
      element.library?.name == _NG_META_LIB_NAME;

  @override
  bool get isVisibleForTesting =>
      element is PropertyAccessorElement &&
      element.name == _VISIBLE_FOR_TESTING_VARIABLE_NAME &&
      element.library?.name == _META_LIB_NAME;

  /// Get the library containing this annotation.
  Source get librarySource => compilationUnit.librarySource;

  @override
  Source get source => compilationUnit.source;

  @override
  DartObject computeConstantValue() {
    if (evaluationResult == null) {
      AnalysisOptionsImpl analysisOptions = context.analysisOptions;
      computeConstants(context.typeProvider, context.typeSystem,
          context.declaredVariables, [this], analysisOptions.experimentStatus);
    }
    return constantValue;
  }

  @override
  String toSource() => annotationAst.toSource();

  @override
  String toString() => '@$element';
}

/// A base class for concrete implementations of an [Element].
abstract class ElementImpl implements Element {
  /// An Unicode right arrow.
  @deprecated
  static final String RIGHT_ARROW = " \u2192 ";

  static int _NEXT_ID = 0;

  final int id = _NEXT_ID++;

  /// The enclosing element of this element, or `null` if this element is at the
  /// root of the element structure.
  ElementImpl _enclosingElement;

  Reference reference;
  final AstNode linkedNode;

  /// The name of this element.
  String _name;

  /// The offset of the name of this element in the file that contains the
  /// declaration of this element.
  int _nameOffset = 0;

  /// A bit-encoded form of the modifiers associated with this element.
  int _modifiers = 0;

  /// A list containing all of the metadata associated with this element.
  List<ElementAnnotation> _metadata;

  /// A cached copy of the calculated hashCode for this element.
  int _cachedHashCode;

  /// A cached copy of the calculated location for this element.
  ElementLocation _cachedLocation;

  /// The documentation comment for this element.
  String _docComment;

  /// The offset of the beginning of the element's code in the file that
  /// contains the element, or `null` if the element is synthetic.
  int _codeOffset;

  /// The length of the element's code, or `null` if the element is synthetic.
  int _codeLength;

  /// Initialize a newly created element to have the given [name] at the given
  /// [_nameOffset].
  ElementImpl(String name, this._nameOffset, {this.reference})
      : linkedNode = null {
    this._name = StringUtilities.intern(name);
    this.reference?.element = this;
  }

  /// Initialize from linked node.
  ElementImpl.forLinkedNode(
      this._enclosingElement, this.reference, this.linkedNode) {
    reference?.element ??= this;
  }

  /// Initialize a newly created element to have the given [name].
  ElementImpl.forNode(Identifier name)
      : this(name == null ? "" : name.name, name == null ? -1 : name.offset);

  /// Initialize from serialized information.
  ElementImpl.forSerialized(this._enclosingElement)
      : reference = null,
        linkedNode = null;

  /// The length of the element's code, or `null` if the element is synthetic.
  int get codeLength => _codeLength;

  /// The offset of the beginning of the element's code in the file that
  /// contains the element, or `null` if the element is synthetic.
  int get codeOffset => _codeOffset;

  @override
  AnalysisContext get context {
    if (_enclosingElement == null) {
      return null;
    }
    return _enclosingElement.context;
  }

  @override
  String get displayName => _name;

  @override
  String get documentationComment => _docComment;

  /// The documentation comment source for this element.
  void set documentationComment(String doc) {
    _docComment = doc?.replaceAll('\r\n', '\n');
  }

  @override
  Element get enclosingElement => _enclosingElement;

  /// Set the enclosing element of this element to the given [element].
  void set enclosingElement(Element element) {
    _enclosingElement = element as ElementImpl;
  }

  /// Return the enclosing unit element (which might be the same as `this`), or
  /// `null` if this element is not contained in any compilation unit.
  CompilationUnitElementImpl get enclosingUnit {
    return _enclosingElement?.enclosingUnit;
  }

  @override
  bool get hasAlwaysThrows {
    var metadata = this.metadata;
    for (var i = 0; i < metadata.length; i++) {
      var annotation = metadata[i];
      if (annotation.isAlwaysThrows) {
        return true;
      }
    }
    return false;
  }

  @override
  bool get hasDeprecated {
    var metadata = this.metadata;
    for (var i = 0; i < metadata.length; i++) {
      var annotation = metadata[i];
      if (annotation.isDeprecated) {
        return true;
      }
    }
    return false;
  }

  @override
  bool get hasFactory {
    var metadata = this.metadata;
    for (var i = 0; i < metadata.length; i++) {
      var annotation = metadata[i];
      if (annotation.isFactory) {
        return true;
      }
    }
    return false;
  }

  @override
  int get hashCode {
    // TODO: We might want to re-visit this optimization in the future.
    // We cache the hash code value as this is a very frequently called method.
    if (_cachedHashCode == null) {
      _cachedHashCode = location.hashCode;
    }
    return _cachedHashCode;
  }

  @override
  bool get hasIsTest {
    var metadata = this.metadata;
    for (var i = 0; i < metadata.length; i++) {
      var annotation = metadata[i];
      if (annotation.isIsTest) {
        return true;
      }
    }
    return false;
  }

  @override
  bool get hasIsTestGroup {
    var metadata = this.metadata;
    for (var i = 0; i < metadata.length; i++) {
      var annotation = metadata[i];
      if (annotation.isIsTestGroup) {
        return true;
      }
    }
    return false;
  }

  @override
  bool get hasJS {
    var metadata = this.metadata;
    for (var i = 0; i < metadata.length; i++) {
      var annotation = metadata[i];
      if (annotation.isJS) {
        return true;
      }
    }
    return false;
  }

  @override
  bool get hasLiteral {
    var metadata = this.metadata;
    for (var i = 0; i < metadata.length; i++) {
      var annotation = metadata[i];
      if (annotation.isLiteral) {
        return true;
      }
    }
    return false;
  }

  @override
  bool get hasMustCallSuper {
    var metadata = this.metadata;
    for (var i = 0; i < metadata.length; i++) {
      var annotation = metadata[i];
      if (annotation.isMustCallSuper) {
        return true;
      }
    }
    return false;
  }

  @override
  bool get hasNonVirtual {
    var metadata = this.metadata;
    for (var i = 0; i < metadata.length; i++) {
      var annotation = metadata[i];
      if (annotation.isNonVirtual) {
        return true;
      }
    }
    return false;
  }

  @override
  bool get hasOptionalTypeArgs {
    var metadata = this.metadata;
    for (var i = 0; i < metadata.length; i++) {
      var annotation = metadata[i];
      if (annotation.isOptionalTypeArgs) {
        return true;
      }
    }
    return false;
  }

  @override
  bool get hasOverride {
    var metadata = this.metadata;
    for (var i = 0; i < metadata.length; i++) {
      var annotation = metadata[i];
      if (annotation.isOverride) {
        return true;
      }
    }
    return false;
  }

  @override
  bool get hasProtected {
    var metadata = this.metadata;
    for (var i = 0; i < metadata.length; i++) {
      var annotation = metadata[i];
      if (annotation.isProtected) {
        return true;
      }
    }
    return false;
  }

  @override
  bool get hasRequired {
    var metadata = this.metadata;
    for (var i = 0; i < metadata.length; i++) {
      var annotation = metadata[i];
      if (annotation.isRequired) {
        return true;
      }
    }
    return false;
  }

  @override
  bool get hasSealed {
    var metadata = this.metadata;
    for (var i = 0; i < metadata.length; i++) {
      var annotation = metadata[i];
      if (annotation.isSealed) {
        return true;
      }
    }
    return false;
  }

  @override
  bool get hasVisibleForTemplate {
    var metadata = this.metadata;
    for (var i = 0; i < metadata.length; i++) {
      var annotation = metadata[i];
      if (annotation.isVisibleForTemplate) {
        return true;
      }
    }
    return false;
  }

  @override
  bool get hasVisibleForTesting {
    var metadata = this.metadata;
    for (var i = 0; i < metadata.length; i++) {
      var annotation = metadata[i];
      if (annotation.isVisibleForTesting) {
        return true;
      }
    }
    return false;
  }

  /// Return an identifier that uniquely identifies this element among the
  /// children of this element's parent.
  String get identifier => name;

  @override
  bool get isPrivate {
    String name = displayName;
    if (name == null) {
      return true;
    }
    return Identifier.isPrivateName(name);
  }

  @override
  bool get isPublic => !isPrivate;

  @override
  bool get isSynthetic {
    if (linkedNode != null) {
      return linkedNode.isSynthetic;
    }
    return hasModifier(Modifier.SYNTHETIC);
  }

  /// Set whether this element is synthetic.
  void set isSynthetic(bool isSynthetic) {
    setModifier(Modifier.SYNTHETIC, isSynthetic);
  }

  @override
  LibraryElement get library =>
      getAncestor((element) => element is LibraryElement);

  @override
  Source get librarySource => library?.source;

  LinkedUnitContext get linkedContext {
    return _enclosingElement.linkedContext;
  }

  @override
  ElementLocation get location {
    if (_cachedLocation == null) {
      if (library == null) {
        return new ElementLocationImpl.con1(this);
      }
      _cachedLocation = new ElementLocationImpl.con1(this);
    }
    return _cachedLocation;
  }

  List<ElementAnnotation> get metadata {
    if (linkedNode != null) {
      if (_metadata != null) return _metadata;
      var metadata = linkedContext.getMetadata(linkedNode);
      return _metadata = _buildAnnotations2(enclosingUnit, metadata);
    }
    return _metadata ?? const <ElementAnnotation>[];
  }

  void set metadata(List<ElementAnnotation> metadata) {
    _metadata = metadata;
  }

  @override
  String get name => _name;

  /// Changes the name of this element.
  void set name(String name) {
    this._name = name;
  }

  @override
  int get nameLength => displayName != null ? displayName.length : 0;

  @override
  int get nameOffset => _nameOffset;

  /// Sets the offset of the name of this element in the file that contains the
  /// declaration of this element.
  void set nameOffset(int offset) {
    _nameOffset = offset;
  }

  @override
  AnalysisSession get session {
    return _enclosingElement?.session;
  }

  @override
  Source get source {
    if (_enclosingElement == null) {
      return null;
    }
    return _enclosingElement.source;
  }

  /// Return the context to resolve type parameters in, or `null` if neither
  /// this element nor any of its ancestors is of a kind that can declare type
  /// parameters.
  TypeParameterizedElementMixin get typeParameterContext {
    return _enclosingElement?.typeParameterContext;
  }

  NullabilitySuffix get _noneOrStarSuffix {
    return library?.isNonNullableByDefault == true
        ? NullabilitySuffix.none
        : NullabilitySuffix.star;
  }

  @override
  bool operator ==(Object object) {
    if (identical(this, object)) {
      return true;
    }
    return object is Element &&
        object.kind == kind &&
        object.location == location;
  }

  /// Append a textual representation of this element to the given [buffer].
  void appendTo(StringBuffer buffer) {
    if (_name == null) {
      buffer.write("<unnamed ");
      buffer.write(runtimeType.toString());
      buffer.write(">");
    } else {
      buffer.write(_name);
    }
  }

  /// Set this element as the enclosing element for given [element].
  void encloseElement(ElementImpl element) {
    element.enclosingElement = this;
  }

  /// Set this element as the enclosing element for given [elements].
  void encloseElements(List<Element> elements) {
    for (Element element in elements) {
      (element as ElementImpl)._enclosingElement = this;
    }
  }

  @override
  E getAncestor<E extends Element>(Predicate<Element> predicate) {
    var ancestor = _enclosingElement;
    while (ancestor != null && !predicate(ancestor)) {
      ancestor = ancestor.enclosingElement;
    }
    return ancestor as E;
  }

  /// Return the child of this element that is uniquely identified by the given
  /// [identifier], or `null` if there is no such child.
  ElementImpl getChild(String identifier) => null;

  @override
  String getExtendedDisplayName(String shortName) {
    if (shortName == null) {
      shortName = displayName;
    }
    Source source = this.source;
    if (source != null) {
      return "$shortName (${source.fullName})";
    }
    return shortName;
  }

  /// Return `true` if this element has the given [modifier] associated with it.
  bool hasModifier(Modifier modifier) =>
      BooleanArray.get(_modifiers, modifier.ordinal);

  @override
  bool isAccessibleIn(LibraryElement library) {
    if (Identifier.isPrivateName(name)) {
      return library == this.library;
    }
    return true;
  }

  /// Use the given [visitor] to visit all of the [children] in the given array.
  void safelyVisitChildren(List<Element> children, ElementVisitor visitor) {
    if (children != null) {
      for (Element child in children) {
        child.accept(visitor);
      }
    }
  }

  /// Set the code range for this element.
  void setCodeRange(int offset, int length) {
    _codeOffset = offset;
    _codeLength = length;
  }

  /// Set whether the given [modifier] is associated with this element to
  /// correspond to the given [value].
  void setModifier(Modifier modifier, bool value) {
    _modifiers = BooleanArray.set(_modifiers, modifier.ordinal, value);
  }

  @override
  String toString() {
    StringBuffer buffer = new StringBuffer();
    appendTo(buffer);
    return buffer.toString();
  }

  @override
  void visitChildren(ElementVisitor visitor) {
    // There are no children to visit
  }

  /// Return annotations for the given [nodeList] in the [unit].
  List<ElementAnnotation> _buildAnnotations2(
      CompilationUnitElementImpl unit, List<Annotation> nodeList) {
    var length = nodeList.length;
    if (length == 0) {
      return const <ElementAnnotation>[];
    }

    var annotations = new List<ElementAnnotation>(length);
    for (int i = 0; i < length; i++) {
      var ast = nodeList[i];
      annotations[i] = ElementAnnotationImpl(unit)
        ..annotationAst = ast
        ..element = ast.element;
    }
    return annotations;
  }

  /// If the element associated with the given [type] is a generic function type
  /// element, then make it a child of this element. Return the [type] as a
  /// convenience.
  DartType _checkElementOfType(DartType type) {
    Element element = type?.element;
    if (element is GenericFunctionTypeElementImpl &&
        element.enclosingElement == null) {
      element.enclosingElement = this;
    }
    return type;
  }

  /// If the given [type] is a generic function type, then the element
  /// associated with the type is implicitly a child of this element and should
  /// be visited by the given [visitor].
  void _safelyVisitPossibleChild(DartType type, ElementVisitor visitor) {
    Element element = type?.element;
    if (element is GenericFunctionTypeElementImpl &&
        element.enclosingElement is! GenericTypeAliasElement) {
      element.accept(visitor);
    }
  }
}

/// A concrete implementation of an [ElementLocation].
class ElementLocationImpl implements ElementLocation {
  /// The character used to separate components in the encoded form.
  static int _SEPARATOR_CHAR = 0x3B;

  /// The path to the element whose location is represented by this object.
  List<String> _components;

  /// The object managing [indexKeyId] and [indexLocationId].
  Object indexOwner;

  /// A cached id of this location in index.
  int indexKeyId;

  /// A cached id of this location in index.
  int indexLocationId;

  /// Initialize a newly created location to represent the given [element].
  ElementLocationImpl.con1(Element element) {
    List<String> components = new List<String>();
    Element ancestor = element;
    while (ancestor != null) {
      components.insert(0, (ancestor as ElementImpl).identifier);
      ancestor = ancestor.enclosingElement;
    }
    this._components = components;
  }

  /// Initialize a newly created location from the given [encoding].
  ElementLocationImpl.con2(String encoding) {
    this._components = _decode(encoding);
  }

  /// Initialize a newly created location from the given [components].
  ElementLocationImpl.con3(List<String> components) {
    this._components = components;
  }

  @override
  List<String> get components => _components;

  @override
  String get encoding {
    StringBuffer buffer = new StringBuffer();
    int length = _components.length;
    for (int i = 0; i < length; i++) {
      if (i > 0) {
        buffer.writeCharCode(_SEPARATOR_CHAR);
      }
      _encode(buffer, _components[i]);
    }
    return buffer.toString();
  }

  @override
  int get hashCode {
    int result = 0;
    for (int i = 0; i < _components.length; i++) {
      String component = _components[i];
      result = JenkinsSmiHash.combine(result, component.hashCode);
    }
    return result;
  }

  @override
  bool operator ==(Object object) {
    if (identical(this, object)) {
      return true;
    }
    if (object is ElementLocationImpl) {
      List<String> otherComponents = object._components;
      int length = _components.length;
      if (otherComponents.length != length) {
        return false;
      }
      for (int i = 0; i < length; i++) {
        if (_components[i] != otherComponents[i]) {
          return false;
        }
      }
      return true;
    }
    return false;
  }

  @override
  String toString() => encoding;

  /// Decode the [encoding] of a location into a list of components and return
  /// the components.
  List<String> _decode(String encoding) {
    List<String> components = new List<String>();
    StringBuffer buffer = new StringBuffer();
    int index = 0;
    int length = encoding.length;
    while (index < length) {
      int currentChar = encoding.codeUnitAt(index);
      if (currentChar == _SEPARATOR_CHAR) {
        if (index + 1 < length &&
            encoding.codeUnitAt(index + 1) == _SEPARATOR_CHAR) {
          buffer.writeCharCode(_SEPARATOR_CHAR);
          index += 2;
        } else {
          components.add(buffer.toString());
          buffer = new StringBuffer();
          index++;
        }
      } else {
        buffer.writeCharCode(currentChar);
        index++;
      }
    }
    components.add(buffer.toString());
    return components;
  }

  /// Append an encoded form of the given [component] to the given [buffer].
  void _encode(StringBuffer buffer, String component) {
    int length = component.length;
    for (int i = 0; i < length; i++) {
      int currentChar = component.codeUnitAt(i);
      if (currentChar == _SEPARATOR_CHAR) {
        buffer.writeCharCode(_SEPARATOR_CHAR);
      }
      buffer.writeCharCode(currentChar);
    }
  }
}

/// An [AbstractClassElementImpl] which is an enum.
class EnumElementImpl extends AbstractClassElementImpl {
  /// The type defined by the enum.
  InterfaceType _type;

  /// Initialize a newly created class element to have the given [name] at the
  /// given [offset] in the file that contains the declaration of this element.
  EnumElementImpl(String name, int offset) : super(name, offset);

  EnumElementImpl.forLinkedNode(CompilationUnitElementImpl enclosing,
      Reference reference, EnumDeclaration linkedNode)
      : super.forLinkedNode(enclosing, reference, linkedNode);

  /// Initialize a newly created class element to have the given [name].
  EnumElementImpl.forNode(Identifier name) : super.forNode(name);

  @override
  List<PropertyAccessorElement> get accessors {
    if (_accessors == null) {
      if (linkedNode != null) {
        _resynthesizeMembers2();
      }
    }
    return _accessors ?? const <PropertyAccessorElement>[];
  }

  @override
  void set accessors(List<PropertyAccessorElement> accessors) {
    super.accessors = accessors;
  }

  @override
  List<InterfaceType> get allSupertypes => <InterfaceType>[supertype];

  @override
  int get codeLength {
    if (linkedNode != null) {
      return linkedContext.getCodeLength(linkedNode);
    }
    return super.codeLength;
  }

  @override
  int get codeOffset {
    if (linkedNode != null) {
      return linkedContext.getCodeOffset(linkedNode);
    }
    return super.codeOffset;
  }

  @override
  List<ConstructorElement> get constructors {
    // The equivalent code for enums in the spec shows a single constructor,
    // but that constructor is not callable (since it is a compile-time error
    // to subclass, mix-in, implement, or explicitly instantiate an enum).
    // So we represent this as having no constructors.
    return const <ConstructorElement>[];
  }

  @override
  String get documentationComment {
    if (linkedNode != null) {
      var context = enclosingUnit.linkedContext;
      var comment = context.getDocumentationComment(linkedNode);
      return getCommentNodeRawText(comment);
    }
    return super.documentationComment;
  }

  @override
  List<FieldElement> get fields {
    if (_fields == null) {
      if (linkedNode != null) {
        _resynthesizeMembers2();
      }
    }
    return _fields ?? const <FieldElement>[];
  }

  @override
  void set fields(List<FieldElement> fields) {
    super.fields = fields;
  }

  @override
  bool get hasNonFinalField => false;

  @override
  bool get hasReferenceToSuper => false;

  @override
  bool get hasStaticMember => true;

  @override
  List<InterfaceType> get interfaces => const <InterfaceType>[];

  @override
  bool get isAbstract => false;

  @override
  bool get isEnum => true;

  @override
  bool get isMixinApplication => false;

  @override
  bool get isOrInheritsProxy => false;

  @override
  bool get isProxy => false;

  @override
  bool get isSimplyBounded => true;

  @override
  bool get isValidMixin => false;

  @override
  List<MethodElement> get methods {
    if (_methods == null) {
      if (linkedNode != null) {
        _resynthesizeMembers2();
      }
    }
    return _methods ?? const <MethodElement>[];
  }

  @override
  List<InterfaceType> get mixins => const <InterfaceType>[];

  @override
  String get name {
    if (linkedNode != null) {
      return reference.name;
    }
    return super.name;
  }

  @override
  int get nameOffset {
    if (linkedNode != null) {
      return enclosingUnit.linkedContext.getNameOffset(linkedNode);
    }

    return super.nameOffset;
  }

  @override
  InterfaceType get supertype => context.typeProvider.objectType;

  @override
  InterfaceType get type {
    if (_type == null) {
      var typeArguments = const <DartType>[];
      InterfaceTypeImpl type = InterfaceTypeImpl.explicit(this, typeArguments);
      _type = type;
    }
    return _type;
  }

  @override
  List<TypeParameterElement> get typeParameters =>
      const <TypeParameterElement>[];

  @override
  ConstructorElement get unnamedConstructor => null;

  @override
  void appendTo(StringBuffer buffer) {
    buffer.write('enum ');
    String name = displayName;
    if (name == null) {
      buffer.write("{unnamed enum}");
    } else {
      buffer.write(name);
    }
  }

  /// Create the only method enums have - `toString()`.
  void createToStringMethodElement() {
    var method = new MethodElementImpl('toString', -1);
    method.isSynthetic = true;
    method.enclosingElement = this;
    if (linkedNode != null) {
      method.returnType = context.typeProvider.stringType;
      method.reference = reference.getChild('@method').getChild('toString');
    }
    _methods = <MethodElement>[method];
  }

  @override
  ConstructorElement getNamedConstructor(String name) => null;

  void _resynthesizeMembers2() {
    var fields = <FieldElementImpl>[];
    var getters = <PropertyAccessorElementImpl>[];

    // Build the 'index' field.
    {
      var field = FieldElementImpl('index', -1)
        ..enclosingElement = this
        ..isSynthetic = true
        ..isFinal = true
        ..type = context.typeProvider.intType;
      fields.add(field);
      getters.add(PropertyAccessorElementImpl_ImplicitGetter(field,
          reference: reference.getChild('@getter').getChild('index'))
        ..enclosingElement = this);
    }

    // Build the 'values' field.
    {
      var field = ConstFieldElementImpl_EnumValues(this);
      fields.add(field);
      getters.add(PropertyAccessorElementImpl_ImplicitGetter(field,
          reference: reference.getChild('@getter').getChild('values'))
        ..enclosingElement = this);
    }

    // Build fields for all enum constants.
    var containerRef = this.reference.getChild('@constant');
    var constants = linkedContext.getEnumConstants(linkedNode);
    for (var i = 0; i < constants.length; ++i) {
      var constant = constants[i];
      var name = constant.name.name;
      var reference = containerRef.getChild(name);
      var field = new ConstFieldElementImpl_EnumValue.forLinkedNode(
          this, reference, constant, i);
      fields.add(field);
      getters.add(field.getter);
    }

    _fields = fields;
    _accessors = getters;
    createToStringMethodElement();
  }
}

/// A base class for concrete implementations of an [ExecutableElement].
abstract class ExecutableElementImpl extends ElementImpl
    with TypeParameterizedElementMixin
    implements ExecutableElement {
  /// A list containing all of the parameters defined by this executable
  /// element.
  List<ParameterElement> _parameters;

  /// The inferred return type of this executable element.
  DartType _returnType;

  /// The type of function defined by this executable element.
  FunctionType _type;

  /// Initialize a newly created executable element to have the given [name] and
  /// [offset].
  ExecutableElementImpl(String name, int offset, {Reference reference})
      : super(name, offset, reference: reference);

  /// Initialize using the given linked node.
  ExecutableElementImpl.forLinkedNode(
      ElementImpl enclosing, Reference reference, AstNode linkedNode)
      : super.forLinkedNode(enclosing, reference, linkedNode);

  /// Initialize a newly created executable element to have the given [name].
  ExecutableElementImpl.forNode(Identifier name) : super.forNode(name);

  /// Set whether this executable element's body is asynchronous.
  void set asynchronous(bool isAsynchronous) {
    setModifier(Modifier.ASYNCHRONOUS, isAsynchronous);
  }

  @override
  int get codeLength {
    if (linkedNode != null) {
      return linkedContext.getCodeLength(linkedNode);
    }
    return super.codeLength;
  }

  @override
  int get codeOffset {
    if (linkedNode != null) {
      return linkedContext.getCodeOffset(linkedNode);
    }
    return super.codeOffset;
  }

  @override
  String get displayName {
    if (linkedNode != null) {
      return reference.name;
    }
    return super.displayName;
  }

  @override
  String get documentationComment {
    if (linkedNode != null) {
      var context = enclosingUnit.linkedContext;
      var comment = context.getDocumentationComment(linkedNode);
      return getCommentNodeRawText(comment);
    }
    return super.documentationComment;
  }

  /// Set whether this executable element is external.
  void set external(bool isExternal) {
    setModifier(Modifier.EXTERNAL, isExternal);
  }

  /// Set whether this method's body is a generator.
  void set generator(bool isGenerator) {
    setModifier(Modifier.GENERATOR, isGenerator);
  }

  @override
  bool get hasImplicitReturnType {
    if (linkedNode != null) {
      return linkedContext.hasImplicitReturnType(linkedNode);
    }
    return hasModifier(Modifier.IMPLICIT_TYPE);
  }

  /// Set whether this executable element has an implicit return type.
  void set hasImplicitReturnType(bool hasImplicitReturnType) {
    setModifier(Modifier.IMPLICIT_TYPE, hasImplicitReturnType);
  }

  @override
  bool get isAbstract {
    if (linkedNode != null) {
      return !isExternal && enclosingUnit.linkedContext.isAbstract(linkedNode);
    }
    return hasModifier(Modifier.ABSTRACT);
  }

  @override
  bool get isAsynchronous {
    if (linkedNode != null) {
      return enclosingUnit.linkedContext.isAsynchronous(linkedNode);
    }
    return hasModifier(Modifier.ASYNCHRONOUS);
  }

  @override
  bool get isExternal {
    if (linkedNode != null) {
      return enclosingUnit.linkedContext.isExternal(linkedNode);
    }
    return hasModifier(Modifier.EXTERNAL);
  }

  @override
  bool get isGenerator {
    if (linkedNode != null) {
      return enclosingUnit.linkedContext.isGenerator(linkedNode);
    }
    return hasModifier(Modifier.GENERATOR);
  }

  @override
  bool get isOperator => false;

  @override
  bool get isSynchronous => !isAsynchronous;

  @override
  String get name {
    if (linkedNode != null) {
      return reference.name;
    }
    return super.name;
  }

  @override
  int get nameOffset {
    if (linkedNode != null) {
      return enclosingUnit.linkedContext.getNameOffset(linkedNode);
    }

    return super.nameOffset;
  }

  @override
  List<ParameterElement> get parameters {
    if (_parameters != null) return _parameters;

    if (linkedNode != null) {
      var context = enclosingUnit.linkedContext;
      var containerRef = reference.getChild('@parameter');
      var formalParameters = context.getFormalParameters(linkedNode);
      _parameters = ParameterElementImpl.forLinkedNodeList(
        this,
        context,
        containerRef,
        formalParameters,
      );
    }

    return _parameters ??= const <ParameterElement>[];
  }

  /// Set the parameters defined by this executable element to the given
  /// [parameters].
  void set parameters(List<ParameterElement> parameters) {
    for (ParameterElement parameter in parameters) {
      (parameter as ParameterElementImpl).enclosingElement = this;
    }
    this._parameters = parameters;
  }

  @override
  DartType get returnType {
    if (_returnType != null) return _returnType;

    if (linkedNode != null) {
      var context = enclosingUnit.linkedContext;
      return _returnType = context.getReturnType(linkedNode);
    }
    return _returnType;
  }

  void set returnType(DartType returnType) {
    if (linkedNode != null) {
      linkedContext.setReturnType(linkedNode, returnType);
    }
    _returnType = _checkElementOfType(returnType);
    // We do this because of return type inference. At the moment when we
    // create a local function element we don't know yet its return type,
    // because we have not done static type analysis yet.
    // It somewhere it between we access the type of this element, so it gets
    // cached in the element. When we are done static type analysis, we then
    // should clear this cached type to make it right.
    // TODO(scheglov) Remove when type analysis is done in the single pass.
    _type = null;
  }

  @override
  FunctionType get type {
    if (_type != null) return _type;

    // TODO(scheglov) Remove "element" in the breaking changes branch.
    return _type = FunctionTypeImpl.synthetic(
      returnType,
      typeParameters,
      parameters,
      element: this,
      nullabilitySuffix: _noneOrStarSuffix,
    );
  }

  void set type(FunctionType type) {
    _type = type;
  }

  /// Set the type parameters defined by this executable element to the given
  /// [typeParameters].
  void set typeParameters(List<TypeParameterElement> typeParameters) {
    for (TypeParameterElement parameter in typeParameters) {
      (parameter as TypeParameterElementImpl).enclosingElement = this;
    }
    this._typeParameterElements = typeParameters;
  }

  @override
  void appendTo(StringBuffer buffer) {
    appendToWithName(buffer, displayName);
  }

  /// Append a textual representation of this element to the given [buffer]. The
  /// [name] is the name of the executable element or `null` if the element has
  /// no name. If [includeType] is `true` then the return type will be included.
  void appendToWithName(StringBuffer buffer, String name) {
    FunctionType functionType = type;
    if (functionType != null) {
      buffer.write(functionType.returnType);
      if (name != null) {
        buffer.write(' ');
        buffer.write(name);
      }
    } else if (name != null) {
      buffer.write(name);
    }
    if (this.kind != ElementKind.GETTER) {
      int typeParameterCount = typeParameters.length;
      if (typeParameterCount > 0) {
        buffer.write('<');
        for (int i = 0; i < typeParameterCount; i++) {
          if (i > 0) {
            buffer.write(', ');
          }
          (typeParameters[i] as TypeParameterElementImpl).appendTo(buffer);
        }
        buffer.write('>');
      }
      buffer.write('(');
      String closing;
      ParameterKind kind = ParameterKind.REQUIRED;
      int parameterCount = parameters.length;
      for (int i = 0; i < parameterCount; i++) {
        if (i > 0) {
          buffer.write(', ');
        }
        ParameterElement parameter = parameters[i];
        // ignore: deprecated_member_use_from_same_package
        ParameterKind parameterKind = parameter.parameterKind;
        if (parameterKind != kind) {
          if (closing != null) {
            buffer.write(closing);
          }
          if (parameter.isOptionalPositional) {
            buffer.write('[');
            closing = ']';
          } else if (parameter.isNamed) {
            buffer.write('{');
            if (parameter.isRequiredNamed) {
              buffer.write('required ');
            }
            closing = '}';
          } else {
            closing = null;
          }
        }
        kind = parameterKind;
        parameter.appendToWithoutDelimiters(buffer);
      }
      if (closing != null) {
        buffer.write(closing);
      }
      buffer.write(')');
    }
  }

  @override
  ElementImpl getChild(String identifier) {
    for (ParameterElement parameter in parameters) {
      ParameterElementImpl parameterImpl = parameter;
      if (parameterImpl.identifier == identifier) {
        return parameterImpl;
      }
    }
    return null;
  }

  @override
  void visitChildren(ElementVisitor visitor) {
    super.visitChildren(visitor);
    _safelyVisitPossibleChild(returnType, visitor);
    safelyVisitChildren(typeParameters, visitor);
    safelyVisitChildren(parameters, visitor);
  }
}

/// A concrete implementation of an [ExportElement].
class ExportElementImpl extends UriReferencedElementImpl
    implements ExportElement {
  /// The library that is exported from this library by this export directive.
  LibraryElement _exportedLibrary;

  /// The combinators that were specified as part of the export directive in the
  /// order in which they were specified.
  List<NamespaceCombinator> _combinators;

  /// Initialize a newly created export element at the given [offset].
  ExportElementImpl(int offset) : super(null, offset);

  ExportElementImpl.forLinkedNode(
      LibraryElementImpl enclosing, ExportDirective linkedNode)
      : super.forLinkedNode(enclosing, null, linkedNode);

  @override
  List<NamespaceCombinator> get combinators {
    if (_combinators != null) return _combinators;

    if (linkedNode != null) {
      ExportDirective node = linkedNode;
      return _combinators = ImportElementImpl._buildCombinators2(
        enclosingUnit.linkedContext,
        node.combinators,
      );
    }

    return _combinators ?? const <NamespaceCombinator>[];
  }

  void set combinators(List<NamespaceCombinator> combinators) {
    _combinators = combinators;
  }

  @override
  CompilationUnitElementImpl get enclosingUnit {
    LibraryElementImpl enclosingLibrary = enclosingElement;
    return enclosingLibrary._definingCompilationUnit;
  }

  @override
  LibraryElement get exportedLibrary {
    if (_exportedLibrary != null) return _exportedLibrary;

    if (linkedNode != null) {
      return _exportedLibrary = linkedContext.directiveLibrary(linkedNode);
    }

    return _exportedLibrary;
  }

  void set exportedLibrary(LibraryElement exportedLibrary) {
    _exportedLibrary = exportedLibrary;
  }

  @override
  String get identifier => exportedLibrary.name;

  @override
  ElementKind get kind => ElementKind.EXPORT;

  void set metadata(List<ElementAnnotation> metadata) {
    super.metadata = metadata;
  }

  @override
  int get nameOffset {
    if (linkedNode != null) {
      return linkedContext.getDirectiveOffset(linkedNode);
    }

    return super.nameOffset;
  }

  @override
  String get uri {
    if (linkedNode != null) {
      ExportDirective node = linkedNode;
      return node.uri.stringValue;
    }

    return super.uri;
  }

  @override
  T accept<T>(ElementVisitor<T> visitor) => visitor.visitExportElement(this);

  @override
  void appendTo(StringBuffer buffer) {
    buffer.write("export ");
    (exportedLibrary as LibraryElementImpl).appendTo(buffer);
  }
}

/// A concrete implementation of an [ExtensionElement].
class ExtensionElementImpl extends ElementImpl
    with TypeParameterizedElementMixin
    implements ExtensionElement {
  /// The type being extended.
  DartType _extendedType;

  /// A list containing all of the accessors (getters and setters) contained in
  /// this extension.
  List<PropertyAccessorElement> _accessors;

  /// A list containing all of the fields contained in this extension.
  List<FieldElement> _fields;

  /// A list containing all of the methods contained in this extension.
  List<MethodElement> _methods;

  /// Initialize a newly created extension element to have the given [name] at
  /// the given [offset] in the file that contains the declaration of this
  /// element.
  ExtensionElementImpl(String name, int nameOffset) : super(name, nameOffset);

  /// Initialize using the given linked information.
  ExtensionElementImpl.forLinkedNode(CompilationUnitElementImpl enclosing,
      Reference reference, AstNode linkedNode)
      : super.forLinkedNode(enclosing, reference, linkedNode);

  /// Initialize a newly created extension element to have the given [name].
  ExtensionElementImpl.forNode(Identifier name) : super.forNode(name);

  @override
  List<PropertyAccessorElement> get accessors {
    if (_accessors != null) {
      return _accessors;
    }

    if (linkedNode != null) {
      if (linkedNode is ExtensionDeclaration) {
        _createPropertiesAndAccessors();
        assert(_accessors != null);
        return _accessors;
      } else {
        return _accessors = const [];
      }
    }

    return _accessors ??= const <PropertyAccessorElement>[];
  }

  void set accessors(List<PropertyAccessorElement> accessors) {
    for (PropertyAccessorElement accessor in accessors) {
      (accessor as PropertyAccessorElementImpl).enclosingElement = this;
    }
    _accessors = accessors;
  }

  @override
  int get codeLength {
    if (linkedNode != null) {
      return linkedContext.getCodeLength(linkedNode);
    }
    return super.codeLength;
  }

  @override
  int get codeOffset {
    if (linkedNode != null) {
      return linkedContext.getCodeOffset(linkedNode);
    }
    return super.codeOffset;
  }

  @override
  String get displayName => name;

  @override
  String get documentationComment {
    if (linkedNode != null) {
      var context = enclosingUnit.linkedContext;
      var comment = context.getDocumentationComment(linkedNode);
      return getCommentNodeRawText(comment);
    }
    return super.documentationComment;
  }

  @override
  DartType get extendedType {
    if (_extendedType != null) return _extendedType;

    if (linkedNode != null) {
      return _extendedType = linkedContext.getExtendedType(linkedNode).type;
    }

    return _extendedType;
  }

  void set extendedType(DartType extendedType) {
    _extendedType = extendedType;
  }

  @override
  List<FieldElement> get fields {
    if (_fields != null) {
      return _fields;
    }

    if (linkedNode != null) {
      if (linkedNode is ExtensionDeclaration) {
        _createPropertiesAndAccessors();
        assert(_fields != null);
        return _fields;
      } else {
        return _fields = const [];
      }
    }

    return _fields ?? const <FieldElement>[];
  }

  void set fields(List<FieldElement> fields) {
    for (FieldElement field in fields) {
      (field as FieldElementImpl).enclosingElement = this;
    }
    _fields = fields;
  }

  @override
  String get identifier {
    if (linkedNode != null) {
      return reference.name;
    }
    return super.identifier;
  }

  @override
  bool get isSimplyBounded => true;

  @override
  ElementKind get kind => ElementKind.EXTENSION;

  @override
  List<MethodElement> get methods {
    if (_methods != null) {
      return _methods;
    }

    if (linkedNode != null) {
      var context = enclosingUnit.linkedContext;
      var containerRef = reference.getChild('@method');
      return _methods = context
          .getMethods(linkedNode)
          .where((node) => node.propertyKeyword == null)
          .map((node) {
        var name = node.name.name;
        var reference = containerRef.getChild(name);
        if (reference.hasElementFor(node)) {
          return reference.element as MethodElement;
        }
        return MethodElementImpl.forLinkedNode(this, reference, node);
      }).toList();
    }
    return _methods = const <MethodElement>[];
  }

  /// Set the methods contained in this extension to the given [methods].
  void set methods(List<MethodElement> methods) {
    for (MethodElement method in methods) {
      (method as MethodElementImpl).enclosingElement = this;
    }
    _methods = methods;
  }

  @override
  String get name {
    if (linkedNode != null) {
      return (linkedNode as ExtensionDeclaration).name?.name ?? '';
    }
    return super.name;
  }

  @override
  int get nameOffset {
    if (linkedNode != null) {
      return enclosingUnit.linkedContext.getNameOffset(linkedNode);
    }

    return super.nameOffset;
  }

  /// Set the type parameters defined by this extension to the given
  /// [typeParameters].
  void set typeParameters(List<TypeParameterElement> typeParameters) {
    for (TypeParameterElement typeParameter in typeParameters) {
      (typeParameter as TypeParameterElementImpl).enclosingElement = this;
    }
    this._typeParameterElements = typeParameters;
  }

  @override
  T accept<T>(ElementVisitor<T> visitor) {
    return visitor.visitExtensionElement(this);
  }

  @override
  void appendTo(StringBuffer buffer) {
    buffer.write('extension ');
    String name = displayName;
    if (name == null) {
      buffer.write("(unnamed)");
    } else {
      buffer.write(name);
    }
    int variableCount = typeParameters.length;
    if (variableCount > 0) {
      buffer.write("<");
      for (int i = 0; i < variableCount; i++) {
        if (i > 0) {
          buffer.write(", ");
        }
        (typeParameters[i] as TypeParameterElementImpl).appendTo(buffer);
      }
      buffer.write(">");
    }
    if (extendedType != null && !extendedType.isObject) {
      buffer.write(' on ');
      buffer.write(extendedType.displayName);
    }
  }

  @override
  PropertyAccessorElement getGetter(String getterName) {
    int length = accessors.length;
    for (int i = 0; i < length; i++) {
      PropertyAccessorElement accessor = accessors[i];
      if (accessor.isGetter && accessor.name == getterName) {
        return accessor;
      }
    }
    return null;
  }

  @override
  MethodElement getMethod(String methodName) {
    int length = methods.length;
    for (int i = 0; i < length; i++) {
      MethodElement method = methods[i];
      if (method.name == methodName) {
        return method;
      }
    }
    return null;
  }

  @override
  PropertyAccessorElement getSetter(String setterName) {
    return AbstractClassElementImpl.getSetterFromAccessors(
        setterName, accessors);
  }

  @override
  void visitChildren(ElementVisitor visitor) {
    super.visitChildren(visitor);
    safelyVisitChildren(accessors, visitor);
    safelyVisitChildren(fields, visitor);
    safelyVisitChildren(methods, visitor);
    safelyVisitChildren(typeParameters, visitor);
  }

  /// Create the accessors and fields when [linkedNode] is not `null`.
  void _createPropertiesAndAccessors() {
    assert(_accessors == null);
    assert(_fields == null);

    var context = enclosingUnit.linkedContext;
    var accessorList = <PropertyAccessorElement>[];
    var fieldList = <FieldElement>[];

    var fields = context.getFields(linkedNode);
    for (var field in fields) {
      var name = field.name.name;
      var fieldElement = FieldElementImpl.forLinkedNodeFactory(
        this,
        reference.getChild('@field').getChild(name),
        field,
      );
      fieldList.add(fieldElement);

      accessorList.add(fieldElement.getter);
      if (fieldElement.setter != null) {
        accessorList.add(fieldElement.setter);
      }
    }

    var methods = context.getMethods(linkedNode);
    for (var method in methods) {
      var isGetter = method.isGetter;
      var isSetter = method.isSetter;
      if (!isGetter && !isSetter) continue;

      var name = method.name.name;
      var containerRef = isGetter
          ? reference.getChild('@getter')
          : reference.getChild('@setter');

      var accessorElement = PropertyAccessorElementImpl.forLinkedNode(
        this,
        containerRef.getChild(name),
        method,
      );
      accessorList.add(accessorElement);

      var fieldRef = reference.getChild('@field').getChild(name);
      FieldElementImpl field = fieldRef.element;
      if (field == null) {
        field = new FieldElementImpl(name, -1);
        fieldRef.element = field;
        field.enclosingElement = this;
        field.isSynthetic = true;
        field.isFinal = isGetter;
        field.isStatic = accessorElement.isStatic;
        fieldList.add(field);
      } else {
        // TODO(brianwilkerson) Shouldn't this depend on whether there is a
        //  setter?
        field.isFinal = false;
      }

      accessorElement.variable = field;
      if (isGetter) {
        field.getter = accessorElement;
      } else {
        field.setter = accessorElement;
      }
    }

    _accessors = accessorList;
    _fields = fieldList;
  }
}

/// A concrete implementation of a [FieldElement].
class FieldElementImpl extends PropertyInducingElementImpl
    implements FieldElement {
  /// Initialize a newly created synthetic field element to have the given
  /// [name] at the given [offset].
  FieldElementImpl(String name, int offset) : super(name, offset);

  FieldElementImpl.forLinkedNode(
      ElementImpl enclosing, Reference reference, AstNode linkedNode)
      : super.forLinkedNode(enclosing, reference, linkedNode) {
    if (!linkedNode.isSynthetic) {
      var enclosingRef = enclosing.reference;

      this.getter = PropertyAccessorElementImpl_ImplicitGetter(
        this,
        reference: enclosingRef.getChild('@getter').getChild(name),
      );

      if (!isConst && !isFinal) {
        this.setter = PropertyAccessorElementImpl_ImplicitSetter(
          this,
          reference: enclosingRef.getChild('@setter').getChild(name),
        );
      }
    }
  }

  factory FieldElementImpl.forLinkedNodeFactory(
      ElementImpl enclosing, Reference reference, AstNode linkedNode) {
    var context = enclosing.enclosingUnit.linkedContext;
    if (context.shouldBeConstFieldElement(linkedNode)) {
      return ConstFieldElementImpl.forLinkedNode(
        enclosing,
        reference,
        linkedNode,
      );
    }
    return FieldElementImpl.forLinkedNode(enclosing, reference, linkedNode);
  }

  /// Initialize a newly created field element to have the given [name].
  FieldElementImpl.forNode(Identifier name) : super.forNode(name);

  @override
  bool get isCovariant {
    if (linkedNode != null) {
      return linkedContext.isExplicitlyCovariant(linkedNode);
    }

    return hasModifier(Modifier.COVARIANT);
  }

  /// Set whether this field is explicitly marked as being covariant.
  void set isCovariant(bool isCovariant) {
    setModifier(Modifier.COVARIANT, isCovariant);
  }

  @override
  bool get isEnumConstant =>
      enclosingElement is ClassElement &&
      (enclosingElement as ClassElement).isEnum &&
      !isSynthetic;

  @override
  bool get isStatic {
    if (linkedNode != null) {
      return enclosingUnit.linkedContext.isStatic(linkedNode);
    }
    return hasModifier(Modifier.STATIC);
  }

  /// Set whether this field is static.
  void set isStatic(bool isStatic) {
    setModifier(Modifier.STATIC, isStatic);
  }

  @override
  ElementKind get kind => ElementKind.FIELD;

  @override
  T accept<T>(ElementVisitor<T> visitor) => visitor.visitFieldElement(this);
}

/// A [ParameterElementImpl] that has the additional information of the
/// [FieldElement] associated with the parameter.
class FieldFormalParameterElementImpl extends ParameterElementImpl
    implements FieldFormalParameterElement {
  /// The field associated with this field formal parameter.
  FieldElement _field;

  /// Initialize a newly created parameter element to have the given [name] and
  /// [nameOffset].
  FieldFormalParameterElementImpl(String name, int nameOffset)
      : super(name, nameOffset);

  FieldFormalParameterElementImpl.forLinkedNode(
      ElementImpl enclosing, Reference reference, AstNode linkedNode)
      : super.forLinkedNode(enclosing, reference, linkedNode);

  /// Initialize a newly created parameter element to have the given [name].
  FieldFormalParameterElementImpl.forNode(Identifier name)
      : super.forNode(name);

  @override
  FieldElement get field {
    if (_field == null) {
      String fieldName;
      if (linkedNode != null) {
        fieldName = linkedContext.getFieldFormalParameterName(linkedNode);
      }
      if (fieldName != null) {
        Element enclosingConstructor = enclosingElement;
        if (enclosingConstructor is ConstructorElement) {
          Element enclosingClass = enclosingConstructor.enclosingElement;
          if (enclosingClass is ClassElement) {
            FieldElement field = enclosingClass.getField(fieldName);
            if (field != null && !field.isSynthetic) {
              _field = field;
            }
          }
        }
      }
    }
    return _field;
  }

  void set field(FieldElement field) {
    _field = field;
  }

  @override
  bool get isInitializingFormal => true;

  @override
  void set type(DartType type) {
    _type = type;
  }

  @override
  T accept<T>(ElementVisitor<T> visitor) =>
      visitor.visitFieldFormalParameterElement(this);
}

/// A concrete implementation of a [FunctionElement].
class FunctionElementImpl extends ExecutableElementImpl
    implements FunctionElement, FunctionTypedElementImpl {
  /// Initialize a newly created function element to have the given [name] and
  /// [offset].
  FunctionElementImpl(String name, int offset) : super(name, offset);

  FunctionElementImpl.forLinkedNode(ElementImpl enclosing, Reference reference,
      FunctionDeclaration linkedNode)
      : super.forLinkedNode(enclosing, reference, linkedNode);

  /// Initialize a newly created function element to have the given [name].
  FunctionElementImpl.forNode(Identifier name) : super.forNode(name);

  /// Initialize a newly created function element to have no name and the given
  /// [nameOffset]. This is used for function expressions, that have no name.
  FunctionElementImpl.forOffset(int nameOffset) : super("", nameOffset);

  /// Synthesize an unnamed function element that takes [parameters] and returns
  /// [returnType].
  FunctionElementImpl.synthetic(
      List<ParameterElement> parameters, DartType returnType)
      : super("", -1) {
    isSynthetic = true;
    this.returnType = returnType;
    this.parameters = parameters;
  }

  @override
  String get displayName {
    if (linkedNode != null) {
      return reference.name;
    }
    return super.displayName;
  }

  @override
  String get identifier {
    String identifier = super.identifier;
    Element enclosing = this.enclosingElement;
    if (enclosing is ExecutableElement) {
      identifier += "@$nameOffset";
    }
    return identifier;
  }

  @override
  bool get isEntryPoint {
    return isStatic && displayName == FunctionElement.MAIN_FUNCTION_NAME;
  }

  @override
  bool get isStatic => enclosingElement is CompilationUnitElement;

  @override
  ElementKind get kind => ElementKind.FUNCTION;

  @override
  String get name {
    if (linkedNode != null) {
      return reference.name;
    }
    return super.name;
  }

  @override
  T accept<T>(ElementVisitor<T> visitor) => visitor.visitFunctionElement(this);
}

/// Common internal interface shared by elements whose type is a function type.
///
/// Clients may not extend, implement or mix-in this class.
abstract class FunctionTypedElementImpl
    implements ElementImpl, FunctionTypedElement {
  void set returnType(DartType returnType);
}

/// The element used for a generic function type.
///
/// Clients may not extend, implement or mix-in this class.
class GenericFunctionTypeElementImpl extends ElementImpl
    with TypeParameterizedElementMixin
    implements GenericFunctionTypeElement, FunctionTypedElementImpl {
  /// The declared return type of the function.
  DartType _returnType;

  /// The elements representing the parameters of the function.
  List<ParameterElement> _parameters;

  /// The type defined by this element.
  FunctionType _type;

  GenericFunctionTypeElementImpl.forLinkedNode(
      ElementImpl enclosingElement, Reference reference, AstNode linkedNode)
      : super.forLinkedNode(enclosingElement, reference, linkedNode);

  /// Initialize a newly created function element to have no name and the given
  /// [nameOffset]. This is used for function expressions, that have no name.
  GenericFunctionTypeElementImpl.forOffset(int nameOffset)
      : super("", nameOffset);

  @override
  String get identifier => '-';

  @override
  ElementKind get kind => ElementKind.GENERIC_FUNCTION_TYPE;

  @override
  List<ParameterElement> get parameters {
    if (_parameters == null) {
      if (linkedNode != null) {
        var context = enclosingUnit.linkedContext;
        return _parameters = ParameterElementImpl.forLinkedNodeList(
          this,
          context,
          reference.getChild('@parameter'),
          context.getFormalParameters(linkedNode),
        );
      }
    }
    return _parameters ?? const <ParameterElement>[];
  }

  /// Set the parameters defined by this function type element to the given
  /// [parameters].
  void set parameters(List<ParameterElement> parameters) {
    for (ParameterElement parameter in parameters) {
      (parameter as ParameterElementImpl).enclosingElement = this;
    }
    this._parameters = parameters;
  }

  @override
  DartType get returnType {
    if (_returnType == null) {
      if (linkedNode != null) {
        var context = enclosingUnit.linkedContext;
        return _returnType = context.getReturnType(linkedNode);
      }
    }
    return _returnType;
  }

  /// Set the return type defined by this function type element to the given
  /// [returnType].
  void set returnType(DartType returnType) {
    _returnType = _checkElementOfType(returnType);
  }

  @override
  FunctionType get type {
    if (_type != null) return _type;

    // TODO(scheglov) Remove "element" in the breaking changes branch.
    return _type = FunctionTypeImpl.synthetic(
      returnType,
      typeParameters,
      parameters,
      element: this,
      nullabilitySuffix: _noneOrStarSuffix,
    );
  }

  /// Set the function type defined by this function type element to the given
  /// [type].
  void set type(FunctionType type) {
    _type = type;
  }

  @override
  List<TypeParameterElement> get typeParameters {
    if (linkedNode != null) {
      if (linkedNode is FunctionTypeAlias) {
        return const <TypeParameterElement>[];
      }
    }
    return super.typeParameters;
  }

  /// Set the type parameters defined by this function type element to the given
  /// [typeParameters].
  void set typeParameters(List<TypeParameterElement> typeParameters) {
    for (TypeParameterElement parameter in typeParameters) {
      (parameter as TypeParameterElementImpl).enclosingElement = this;
    }
    this._typeParameterElements = typeParameters;
  }

  @override
  T accept<T>(ElementVisitor<T> visitor) {
    return visitor.visitGenericFunctionTypeElement(this);
  }

  @override
  void appendTo(StringBuffer buffer) {
    DartType type = returnType;
    if (type is TypeImpl) {
      type.appendTo(buffer, new HashSet<TypeImpl>());
      buffer.write(' Function');
    } else {
      buffer.write('Function');
    }
    List<TypeParameterElement> typeParams = typeParameters;
    int typeParameterCount = typeParams.length;
    if (typeParameterCount > 0) {
      buffer.write('<');
      for (int i = 0; i < typeParameterCount; i++) {
        if (i > 0) {
          buffer.write(', ');
        }
        (typeParams[i] as TypeParameterElementImpl).appendTo(buffer);
      }
      buffer.write('>');
    }
    List<ParameterElement> params = parameters;
    buffer.write('(');
    for (int i = 0; i < params.length; i++) {
      if (i > 0) {
        buffer.write(', ');
      }
      (params[i] as ParameterElementImpl).appendTo(buffer);
    }
    buffer.write(')');
  }

  @override
  void visitChildren(ElementVisitor visitor) {
    super.visitChildren(visitor);
    _safelyVisitPossibleChild(returnType, visitor);
    safelyVisitChildren(typeParameters, visitor);
    safelyVisitChildren(parameters, visitor);
  }
}

/// A function type alias of the form
///     `typedef` identifier typeParameters = genericFunctionType;
///
/// Clients may not extend, implement or mix-in this class.
class GenericTypeAliasElementImpl extends ElementImpl
    with TypeParameterizedElementMixin
    implements GenericTypeAliasElement {
  /// The element representing the generic function type.
  GenericFunctionTypeElementImpl _function;

  /// The type of function defined by this type alias.
  FunctionType _type;

  /// Initialize a newly created type alias element to have the given [name].
  GenericTypeAliasElementImpl(String name, int offset) : super(name, offset);

  GenericTypeAliasElementImpl.forLinkedNode(
      CompilationUnitElementImpl enclosingUnit,
      Reference reference,
      AstNode linkedNode)
      : super.forLinkedNode(enclosingUnit, reference, linkedNode);

  /// Initialize a newly created type alias element to have the given [name].
  GenericTypeAliasElementImpl.forNode(Identifier name) : super.forNode(name);

  @override
  int get codeLength {
    if (linkedNode != null) {
      return linkedContext.getCodeLength(linkedNode);
    }
    return super.codeLength;
  }

  @override
  int get codeOffset {
    if (linkedNode != null) {
      return linkedContext.getCodeOffset(linkedNode);
    }
    return super.codeOffset;
  }

  @override
  String get displayName => name;

  @override
  String get documentationComment {
    if (linkedNode != null) {
      var context = enclosingUnit.linkedContext;
      var comment = context.getDocumentationComment(linkedNode);
      return getCommentNodeRawText(comment);
    }
    return super.documentationComment;
  }

  @override
  CompilationUnitElement get enclosingElement =>
      super.enclosingElement as CompilationUnitElement;

  @override
  CompilationUnitElementImpl get enclosingUnit =>
      _enclosingElement as CompilationUnitElementImpl;

  @override
  GenericFunctionTypeElementImpl get function {
    if (_function != null) return _function;

    if (linkedNode != null) {
      if (linkedNode is GenericTypeAlias) {
        var context = enclosingUnit.linkedContext;
        var function = context.getGeneticTypeAliasFunction(linkedNode);
        if (function != null) {
          var reference = context.getGenericFunctionTypeReference(function);
          _function = reference.element;
          encloseElement(_function);
          return _function;
        } else {
          return null;
        }
      } else {
        return _function = GenericFunctionTypeElementImpl.forLinkedNode(
          this,
          reference.getChild('@function'),
          linkedNode,
        );
      }
    }

    return _function;
  }

  /// Set the function element representing the generic function type on the
  /// right side of the equals to the given [function].
  void set function(GenericFunctionTypeElementImpl function) {
    if (function != null) {
      function.enclosingElement = this;
    }
    _function = function;
  }

  bool get hasSelfReference {
    if (linkedNode != null) {
      return linkedContext.getHasTypedefSelfReference(linkedNode);
    }
    return false;
  }

  @override
  bool get isSimplyBounded {
    if (linkedNode != null) {
      return linkedContext.isSimplyBounded(linkedNode);
    }
    return super.isSimplyBounded;
  }

  @override
  ElementKind get kind => ElementKind.FUNCTION_TYPE_ALIAS;

  @override
  String get name {
    if (linkedNode != null) {
      return reference.name;
    }
    return super.name;
  }

  @override
  int get nameOffset {
    if (linkedNode != null) {
      return enclosingUnit.linkedContext.getNameOffset(linkedNode);
    }

    return super.nameOffset;
  }

  @override
  List<ParameterElement> get parameters =>
      function?.parameters ?? const <ParameterElement>[];

  @override
  DartType get returnType {
    if (function == null) {
      // TODO(scheglov) The context is null in unit tests.
      return context?.typeProvider?.dynamicType;
    }
    return function?.returnType;
  }

  @override
  FunctionType get type {
    _type ??= FunctionTypeImpl.synthetic(
      returnType,
      typeParameters,
      parameters,
      element: this,
      typeArguments: typeParameters.map((e) {
        return e.instantiate(
          nullabilitySuffix: NullabilitySuffix.star,
        );
      }).toList(),
      nullabilitySuffix: NullabilitySuffix.star,
    );
    return _type;
  }

  void set type(FunctionType type) {
    _type = type;
  }

  /// Set the type parameters defined for this type to the given
  /// [typeParameters].
  void set typeParameters(List<TypeParameterElement> typeParameters) {
    for (TypeParameterElement typeParameter in typeParameters) {
      (typeParameter as TypeParameterElementImpl).enclosingElement = this;
    }
    this._typeParameterElements = typeParameters;
  }

  @override
  T accept<T>(ElementVisitor<T> visitor) =>
      visitor.visitFunctionTypeAliasElement(this);

  @override
  void appendTo(StringBuffer buffer) {
    buffer.write("typedef ");
    buffer.write(displayName);
    var typeParameters = this.typeParameters;
    int typeParameterCount = typeParameters.length;
    if (typeParameterCount > 0) {
      buffer.write("<");
      for (int i = 0; i < typeParameterCount; i++) {
        if (i > 0) {
          buffer.write(", ");
        }
        (typeParameters[i] as TypeParameterElementImpl).appendTo(buffer);
      }
      buffer.write(">");
    }
    buffer.write(" = ");
    if (function != null) {
      function.appendTo(buffer);
    }
  }

  @override
  ElementImpl getChild(String identifier) {
    for (TypeParameterElement typeParameter in typeParameters) {
      TypeParameterElementImpl typeParameterImpl = typeParameter;
      if (typeParameterImpl.identifier == identifier) {
        return typeParameterImpl;
      }
    }
    return null;
  }

  @override
  FunctionType instantiate({
    @required List<DartType> typeArguments,
    @required NullabilitySuffix nullabilitySuffix,
  }) {
    if (function == null) {
      return null;
    }

    if (typeArguments.length != typeParameters.length) {
      throw new ArgumentError(
          "typeArguments.length (${typeArguments.length}) != "
          "typeParameters.length (${typeParameters.length})");
    }

    var substitution = Substitution.fromPairs(typeParameters, typeArguments);
    var type = substitution.substituteType(function.type) as FunctionType;
    return FunctionTypeImpl.synthetic(
      type.returnType,
      type.typeFormals,
      type.parameters,
      element: this,
      typeArguments: typeArguments,
      nullabilitySuffix: nullabilitySuffix,
    );
  }

  @override
  @deprecated
  FunctionType instantiate2({
    @required List<DartType> typeArguments,
    @required NullabilitySuffix nullabilitySuffix,
  }) {
    return instantiate(
      typeArguments: typeArguments,
      nullabilitySuffix: nullabilitySuffix,
    );
  }

  @override
  void visitChildren(ElementVisitor visitor) {
    super.visitChildren(visitor);
    safelyVisitChildren(typeParameters, visitor);
    function?.accept(visitor);
  }
}

/// A concrete implementation of a [HideElementCombinator].
class HideElementCombinatorImpl implements HideElementCombinator {
  final LinkedUnitContext linkedContext;
  final HideCombinator linkedNode;

  /// The names that are not to be made visible in the importing library even if
  /// they are defined in the imported library.
  List<String> _hiddenNames;

  HideElementCombinatorImpl()
      : linkedContext = null,
        linkedNode = null;

  HideElementCombinatorImpl.forLinkedNode(this.linkedContext, this.linkedNode);

  @override
  List<String> get hiddenNames {
    if (_hiddenNames != null) return _hiddenNames;

    if (linkedNode != null) {
      return _hiddenNames = linkedNode.hiddenNames.map((i) => i.name).toList();
    }

    return _hiddenNames ?? const <String>[];
  }

  void set hiddenNames(List<String> hiddenNames) {
    _hiddenNames = hiddenNames;
  }

  @override
  String toString() {
    StringBuffer buffer = new StringBuffer();
    buffer.write("show ");
    int count = hiddenNames.length;
    for (int i = 0; i < count; i++) {
      if (i > 0) {
        buffer.write(", ");
      }
      buffer.write(hiddenNames[i]);
    }
    return buffer.toString();
  }
}

/// A concrete implementation of an [ImportElement].
class ImportElementImpl extends UriReferencedElementImpl
    implements ImportElement {
  /// The offset of the prefix of this import in the file that contains the this
  /// import directive, or `-1` if this import is synthetic.
  int _prefixOffset = 0;

  /// The library that is imported into this library by this import directive.
  LibraryElement _importedLibrary;

  /// The combinators that were specified as part of the import directive in the
  /// order in which they were specified.
  List<NamespaceCombinator> _combinators;

  /// The prefix that was specified as part of the import directive, or `null
  ///` if there was no prefix specified.
  PrefixElement _prefix;

  /// The cached value of [namespace].
  Namespace _namespace;

  /// Initialize a newly created import element at the given [offset].
  /// The offset may be `-1` if the import is synthetic.
  ImportElementImpl(int offset) : super(null, offset);

  ImportElementImpl.forLinkedNode(
      LibraryElementImpl enclosing, ImportDirective linkedNode)
      : super.forLinkedNode(enclosing, null, linkedNode);

  @override
  List<NamespaceCombinator> get combinators {
    if (_combinators != null) return _combinators;

    if (linkedNode != null) {
      ImportDirective node = linkedNode;
      return _combinators = ImportElementImpl._buildCombinators2(
        enclosingUnit.linkedContext,
        node.combinators,
      );
    }

    return _combinators ?? const <NamespaceCombinator>[];
  }

  void set combinators(List<NamespaceCombinator> combinators) {
    _combinators = combinators;
  }

  /// Set whether this import is for a deferred library.
  void set deferred(bool isDeferred) {
    setModifier(Modifier.DEFERRED, isDeferred);
  }

  @override
  CompilationUnitElementImpl get enclosingUnit {
    LibraryElementImpl enclosingLibrary = enclosingElement;
    return enclosingLibrary._definingCompilationUnit;
  }

  @override
  String get identifier => "${importedLibrary.identifier}@$nameOffset";

  @override
  LibraryElement get importedLibrary {
    if (_importedLibrary != null) return _importedLibrary;

    if (linkedNode != null) {
      return _importedLibrary = linkedContext.directiveLibrary(linkedNode);
    }

    return _importedLibrary;
  }

  void set importedLibrary(LibraryElement importedLibrary) {
    _importedLibrary = importedLibrary;
  }

  @override
  bool get isDeferred {
    if (linkedNode != null) {
      ImportDirective linkedNode = this.linkedNode;
      return linkedNode.deferredKeyword != null;
    }
    return hasModifier(Modifier.DEFERRED);
  }

  @override
  ElementKind get kind => ElementKind.IMPORT;

  void set metadata(List<ElementAnnotation> metadata) {
    super.metadata = metadata;
  }

  @override
  int get nameOffset {
    if (linkedNode != null) {
      return linkedContext.getDirectiveOffset(linkedNode);
    }

    return super.nameOffset;
  }

  @override
  Namespace get namespace {
    return _namespace ??=
        new NamespaceBuilder().createImportNamespaceForDirective(this);
  }

  PrefixElement get prefix {
    if (_prefix != null) return _prefix;

    if (linkedNode != null) {
      ImportDirective linkedNode = this.linkedNode;
      var prefix = linkedNode.prefix;
      if (prefix != null) {
        var name = prefix.name;
        var library = enclosingElement as LibraryElementImpl;
        _prefix = new PrefixElementImpl.forLinkedNode(
          library,
          library.reference.getChild('@prefix').getChild(name),
          prefix,
        );
      }
    }

    return _prefix;
  }

  void set prefix(PrefixElement prefix) {
    _prefix = prefix;
  }

  @override
  int get prefixOffset {
    if (linkedNode != null) {
      ImportDirective node = linkedNode;
      return node.prefix?.offset ?? -1;
    }
    return _prefixOffset;
  }

  void set prefixOffset(int prefixOffset) {
    _prefixOffset = prefixOffset;
  }

  @override
  String get uri {
    if (linkedNode != null) {
      ImportDirective node = linkedNode;
      return node.uri.stringValue;
    }

    return super.uri;
  }

  @override
  void set uri(String uri) {
    super.uri = uri;
  }

  @override
  T accept<T>(ElementVisitor<T> visitor) => visitor.visitImportElement(this);

  @override
  void appendTo(StringBuffer buffer) {
    buffer.write("import ");
    (importedLibrary as LibraryElementImpl).appendTo(buffer);
  }

  @override
  void visitChildren(ElementVisitor visitor) {
    super.visitChildren(visitor);
    prefix?.accept(visitor);
  }

  static List<NamespaceCombinator> _buildCombinators2(
      LinkedUnitContext context, List<Combinator> combinators) {
    return combinators.map((node) {
      if (node is HideCombinator) {
        return HideElementCombinatorImpl.forLinkedNode(context, node);
      }
      if (node is ShowCombinator) {
        return ShowElementCombinatorImpl.forLinkedNode(context, node);
      }
      throw UnimplementedError('${node.runtimeType}');
    }).toList();
  }
}

/// A concrete implementation of a [LabelElement].
class LabelElementImpl extends ElementImpl implements LabelElement {
  /// A flag indicating whether this label is associated with a `switch`
  /// statement.
  // TODO(brianwilkerson) Make this a modifier.
  final bool _onSwitchStatement;

  /// A flag indicating whether this label is associated with a `switch` member
  /// (`case` or `default`).
  // TODO(brianwilkerson) Make this a modifier.
  final bool _onSwitchMember;

  /// Initialize a newly created label element to have the given [name].
  /// [onSwitchStatement] should be `true` if this label is associated with a
  /// `switch` statement and [onSwitchMember] should be `true` if this label is
  /// associated with a `switch` member.
  LabelElementImpl(String name, int nameOffset, this._onSwitchStatement,
      this._onSwitchMember)
      : super(name, nameOffset);

  /// Initialize a newly created label element to have the given [name].
  /// [_onSwitchStatement] should be `true` if this label is associated with a
  /// `switch` statement and [_onSwitchMember] should be `true` if this label is
  /// associated with a `switch` member.
  LabelElementImpl.forNode(
      Identifier name, this._onSwitchStatement, this._onSwitchMember)
      : super.forNode(name);

  @override
  String get displayName => name;

  @override
  ExecutableElement get enclosingElement =>
      super.enclosingElement as ExecutableElement;

  /// Return `true` if this label is associated with a `switch` member (`case
  /// ` or`default`).
  bool get isOnSwitchMember => _onSwitchMember;

  /// Return `true` if this label is associated with a `switch` statement.
  bool get isOnSwitchStatement => _onSwitchStatement;

  @override
  ElementKind get kind => ElementKind.LABEL;

  @override
  T accept<T>(ElementVisitor<T> visitor) => visitor.visitLabelElement(this);
}

/// A concrete implementation of a [LibraryElement].
class LibraryElementImpl extends ElementImpl implements LibraryElement {
  /// The analysis context in which this library is defined.
  final AnalysisContext context;

  @override
  final AnalysisSession session;

  /// The context of the defining unit.
  final LinkedUnitContext linkedContext;

  @override
  final bool isNonNullableByDefault;

  /// The compilation unit that defines this library.
  CompilationUnitElement _definingCompilationUnit;

  /// The entry point for this library, or `null` if this library does not have
  /// an entry point.
  FunctionElement _entryPoint;

  /// A list containing specifications of all of the imports defined in this
  /// library.
  List<ImportElement> _imports;

  /// A list containing specifications of all of the exports defined in this
  /// library.
  List<ExportElement> _exports;

  /// A list containing all of the compilation units that are included in this
  /// library using a `part` directive.
  List<CompilationUnitElement> _parts = const <CompilationUnitElement>[];

  /// The element representing the synthetic function `loadLibrary` that is
  /// defined for this library, or `null` if the element has not yet been
  /// created.
  FunctionElement _loadLibraryFunction;

  @override
  final int nameLength;

  /// The export [Namespace] of this library, `null` if it has not been
  /// computed yet.
  Namespace _exportNamespace;

  /// The public [Namespace] of this library, `null` if it has not been
  /// computed yet.
  Namespace _publicNamespace;

  /// A bit-encoded form of the capabilities associated with this library.
  int _resolutionCapabilities = 0;

  /// The cached list of prefixes.
  List<PrefixElement> _prefixes;

  /// Initialize a newly created library element in the given [context] to have
  /// the given [name] and [offset].
  LibraryElementImpl(this.context, this.session, String name, int offset,
      this.nameLength, this.isNonNullableByDefault)
      : linkedContext = null,
        super(name, offset);

  LibraryElementImpl.forLinkedNode(
      this.context,
      this.session,
      String name,
      int offset,
      this.nameLength,
      this.linkedContext,
      Reference reference,
      CompilationUnit linkedNode)
      : isNonNullableByDefault = linkedContext.isNNBD,
        super.forLinkedNode(null, reference, linkedNode) {
    _name = name;
    _nameOffset = offset;
    setResolutionCapability(
        LibraryResolutionCapability.resolvedTypeNames, true);
    setResolutionCapability(
        LibraryResolutionCapability.constantExpressions, true);
  }

  /// Initialize a newly created library element in the given [context] to have
  /// the given [name].
  LibraryElementImpl.forNode(this.context, this.session, LibraryIdentifier name,
      this.isNonNullableByDefault)
      : nameLength = name != null ? name.length : 0,
        linkedContext = null,
        super.forNode(name);

  @override
  int get codeLength {
    CompilationUnitElement unit = _definingCompilationUnit;
    if (unit is CompilationUnitElementImpl) {
      return unit.codeLength;
    }
    return null;
  }

  @override
  int get codeOffset {
    CompilationUnitElement unit = _definingCompilationUnit;
    if (unit is CompilationUnitElementImpl) {
      return unit.codeOffset;
    }
    return null;
  }

  @override
  CompilationUnitElement get definingCompilationUnit =>
      _definingCompilationUnit;

  /// Set the compilation unit that defines this library to the given
  ///  compilation[unit].
  void set definingCompilationUnit(CompilationUnitElement unit) {
    assert((unit as CompilationUnitElementImpl).librarySource == unit.source);
    (unit as CompilationUnitElementImpl).enclosingElement = this;
    this._definingCompilationUnit = unit;
  }

  @override
  String get documentationComment {
    if (linkedNode != null) {
      var comment = linkedContext.getLibraryDocumentationComment(linkedNode);
      return getCommentNodeRawText(comment);
    }
    return super.documentationComment;
  }

  FunctionElement get entryPoint {
    if (_entryPoint != null) return _entryPoint;

    if (linkedContext != null) {
      var namespace = library.exportNamespace;
      var entryPoint = namespace.get(FunctionElement.MAIN_FUNCTION_NAME);
      if (entryPoint is FunctionElement) {
        return _entryPoint = entryPoint;
      }
      return null;
    }

    return _entryPoint;
  }

  void set entryPoint(FunctionElement entryPoint) {
    _entryPoint = entryPoint;
  }

  @override
  List<LibraryElement> get exportedLibraries {
    HashSet<LibraryElement> libraries = new HashSet<LibraryElement>();
    for (ExportElement element in exports) {
      LibraryElement library = element.exportedLibrary;
      if (library != null) {
        libraries.add(library);
      }
    }
    return libraries.toList(growable: false);
  }

  @override
  Namespace get exportNamespace {
    if (_exportNamespace != null) return _exportNamespace;

    if (linkedNode != null) {
      var elements = linkedContext.bundleContext.elementFactory;
      return _exportNamespace = elements.buildExportNamespace(source.uri);
    }

    return _exportNamespace;
  }

  void set exportNamespace(Namespace exportNamespace) {
    _exportNamespace = exportNamespace;
  }

  @override
  List<ExportElement> get exports {
    if (_exports != null) return _exports;

    if (linkedNode != null) {
      var unit = linkedContext.unit_withDirectives;
      return _exports = unit.directives
          .whereType<ExportDirective>()
          .map((node) => ExportElementImpl.forLinkedNode(this, node))
          .toList();
    }

    return _exports ??= const <ExportElement>[];
  }

  /// Set the specifications of all of the exports defined in this library to
  /// the given list of [exports].
  void set exports(List<ExportElement> exports) {
    for (ExportElement exportElement in exports) {
      (exportElement as ExportElementImpl).enclosingElement = this;
    }
    this._exports = exports;
  }

  @override
  bool get hasExtUri {
    if (linkedNode != null) {
      var unit = linkedContext.unit_withDirectives;
      for (var import in unit.directives) {
        if (import is ImportDirective) {
          var uriStr = linkedContext.getSelectedUri(import);
          if (DartUriResolver.isDartExtUri(uriStr)) {
            return true;
          }
        }
      }
      return false;
    }

    return hasModifier(Modifier.HAS_EXT_URI);
  }

  /// Set whether this library has an import of a "dart-ext" URI.
  void set hasExtUri(bool hasExtUri) {
    setModifier(Modifier.HAS_EXT_URI, hasExtUri);
  }

  @override
  bool get hasLoadLibraryFunction {
    if (_definingCompilationUnit.hasLoadLibraryFunction) {
      return true;
    }
    for (int i = 0; i < _parts.length; i++) {
      if (_parts[i].hasLoadLibraryFunction) {
        return true;
      }
    }
    return false;
  }

  @override
  String get identifier => '${_definingCompilationUnit.source.uri}';

  @override
  List<LibraryElement> get importedLibraries {
    HashSet<LibraryElement> libraries = new HashSet<LibraryElement>();
    for (ImportElement element in imports) {
      LibraryElement library = element.importedLibrary;
      if (library != null) {
        libraries.add(library);
      }
    }
    return libraries.toList(growable: false);
  }

  @override
  List<ImportElement> get imports {
    if (_imports != null) return _imports;

    if (linkedNode != null) {
      var unit = linkedContext.unit_withDirectives;
      _imports = unit.directives
          .whereType<ImportDirective>()
          .map((node) => ImportElementImpl.forLinkedNode(this, node))
          .toList();
      var hasCore = _imports.any((import) {
        return import.importedLibrary?.isDartCore ?? false;
      });
      if (!hasCore) {
        var elements = linkedContext.bundleContext.elementFactory;
        _imports.add(ImportElementImpl(-1)
          ..importedLibrary = elements.libraryOfUri('dart:core')
          ..isSynthetic = true);
      }
      return _imports;
    }

    return _imports ??= const <ImportElement>[];
  }

  /// Set the specifications of all of the imports defined in this library to
  /// the given list of [imports].
  void set imports(List<ImportElement> imports) {
    for (ImportElement importElement in imports) {
      (importElement as ImportElementImpl).enclosingElement = this;
      PrefixElementImpl prefix = importElement.prefix as PrefixElementImpl;
      if (prefix != null) {
        prefix.enclosingElement = this;
      }
    }
    this._imports = imports;
    this._prefixes = null;
  }

  @override
  bool get isBrowserApplication =>
      entryPoint != null && isOrImportsBrowserLibrary;

  @override
  bool get isDartAsync => name == "dart.async";

  @override
  bool get isDartCore => name == "dart.core";

  @override
  bool get isInSdk {
    Uri uri = definingCompilationUnit.source?.uri;
    if (uri != null) {
      return DartUriResolver.isDartUri(uri);
    }
    return false;
  }

  /// Return `true` if the receiver directly or indirectly imports the
  /// 'dart:html' libraries.
  bool get isOrImportsBrowserLibrary {
    List<LibraryElement> visited = new List<LibraryElement>();
    Source htmlLibSource = context.sourceFactory.forUri(DartSdk.DART_HTML);
    visited.add(this);
    for (int index = 0; index < visited.length; index++) {
      LibraryElement library = visited[index];
      Source source = library.definingCompilationUnit.source;
      if (source == htmlLibSource) {
        return true;
      }
      for (LibraryElement importedLibrary in library.importedLibraries) {
        if (!visited.contains(importedLibrary)) {
          visited.add(importedLibrary);
        }
      }
      for (LibraryElement exportedLibrary in library.exportedLibraries) {
        if (!visited.contains(exportedLibrary)) {
          visited.add(exportedLibrary);
        }
      }
    }
    return false;
  }

  @override
  bool get isSynthetic {
    if (linkedNode != null) {
      return linkedContext.isSynthetic;
    }
    return super.isSynthetic;
  }

  @override
  ElementKind get kind => ElementKind.LIBRARY;

  @override
  LibraryElement get library => this;

  @override
  FunctionElement get loadLibraryFunction {
    assert(_loadLibraryFunction != null);
    return _loadLibraryFunction;
  }

  @override
  List<ElementAnnotation> get metadata {
    if (_metadata != null) return _metadata;

    if (linkedNode != null) {
      var metadata = linkedContext.getLibraryMetadata(linkedNode);
      return _metadata = _buildAnnotations2(definingCompilationUnit, metadata);
    }

    return super.metadata;
  }

  @override
  List<CompilationUnitElement> get parts => _parts;

  /// Set the compilation units that are included in this library using a `part`
  /// directive to the given list of [parts].
  void set parts(List<CompilationUnitElement> parts) {
    for (CompilationUnitElement compilationUnit in parts) {
      assert((compilationUnit as CompilationUnitElementImpl).librarySource ==
          source);
      (compilationUnit as CompilationUnitElementImpl).enclosingElement = this;
    }
    this._parts = parts;
  }

  @override
  List<PrefixElement> get prefixes =>
      _prefixes ??= buildPrefixesFromImports(imports);

  @override
  Namespace get publicNamespace {
    if (_publicNamespace != null) return _publicNamespace;

    if (linkedNode != null) {
      return _publicNamespace =
          NamespaceBuilder().createPublicNamespaceForLibrary(this);
    }

    return _publicNamespace;
  }

  void set publicNamespace(Namespace publicNamespace) {
    _publicNamespace = publicNamespace;
  }

  @override
  Source get source {
    if (_definingCompilationUnit == null) {
      return null;
    }
    return _definingCompilationUnit.source;
  }

  @override
  Iterable<Element> get topLevelElements sync* {
    for (var unit in units) {
      yield* unit.accessors;
      yield* unit.enums;
      yield* unit.functionTypeAliases;
      yield* unit.functions;
      yield* unit.mixins;
      yield* unit.topLevelVariables;
      yield* unit.types;
    }
  }

  @override
  List<CompilationUnitElement> get units {
    List<CompilationUnitElement> units = new List<CompilationUnitElement>();
    units.add(_definingCompilationUnit);
    units.addAll(_parts);
    return units;
  }

  @override
  T accept<T>(ElementVisitor<T> visitor) => visitor.visitLibraryElement(this);

  /// Create the [FunctionElement] to be returned by [loadLibraryFunction],
  /// using types provided by [typeProvider].
  void createLoadLibraryFunction(TypeProvider typeProvider) {
    _loadLibraryFunction =
        createLoadLibraryFunctionForLibrary(typeProvider, this);
  }

  @override
  ElementImpl getChild(String identifier) {
    CompilationUnitElementImpl unitImpl = _definingCompilationUnit;
    if (unitImpl.identifier == identifier) {
      return unitImpl;
    }
    for (CompilationUnitElement part in _parts) {
      CompilationUnitElementImpl partImpl = part;
      if (partImpl.identifier == identifier) {
        return partImpl;
      }
    }
    for (ImportElement importElement in imports) {
      ImportElementImpl importElementImpl = importElement;
      if (importElementImpl.identifier == identifier) {
        return importElementImpl;
      }
    }
    for (ExportElement exportElement in exports) {
      ExportElementImpl exportElementImpl = exportElement;
      if (exportElementImpl.identifier == identifier) {
        return exportElementImpl;
      }
    }
    return null;
  }

  ClassElement getEnum(String name) {
    ClassElement element = _definingCompilationUnit.getEnum(name);
    if (element != null) {
      return element;
    }
    for (CompilationUnitElement part in _parts) {
      element = part.getEnum(name);
      if (element != null) {
        return element;
      }
    }
    return null;
  }

  @override
  List<ImportElement> getImportsWithPrefix(PrefixElement prefixElement) {
    return getImportsWithPrefixFromImports(prefixElement, imports);
  }

  @override
  ClassElement getType(String className) {
    return getTypeFromParts(className, _definingCompilationUnit, _parts);
  }

  /// Set whether the library has the given [capability] to
  /// correspond to the given [value].
  void setResolutionCapability(
      LibraryResolutionCapability capability, bool value) {
    _resolutionCapabilities =
        BooleanArray.set(_resolutionCapabilities, capability.index, value);
  }

  @override
  void visitChildren(ElementVisitor visitor) {
    super.visitChildren(visitor);
    _definingCompilationUnit?.accept(visitor);
    safelyVisitChildren(exports, visitor);
    safelyVisitChildren(imports, visitor);
    safelyVisitChildren(_parts, visitor);
  }

  static List<PrefixElement> buildPrefixesFromImports(
      List<ImportElement> imports) {
    HashSet<PrefixElement> prefixes = new HashSet<PrefixElement>();
    for (ImportElement element in imports) {
      PrefixElement prefix = element.prefix;
      if (prefix != null) {
        prefixes.add(prefix);
      }
    }
    return prefixes.toList(growable: false);
  }

  static FunctionElementImpl createLoadLibraryFunctionForLibrary(
      TypeProvider typeProvider, LibraryElement library) {
    FunctionElementImpl function =
        new FunctionElementImpl(FunctionElement.LOAD_LIBRARY_NAME, -1);
    function.isSynthetic = true;
    function.enclosingElement = library;
    function.returnType = typeProvider.futureDynamicType;
    return function;
  }

  static List<ImportElement> getImportsWithPrefixFromImports(
      PrefixElement prefixElement, List<ImportElement> imports) {
    int count = imports.length;
    List<ImportElement> importList = new List<ImportElement>();
    for (int i = 0; i < count; i++) {
      if (identical(imports[i].prefix, prefixElement)) {
        importList.add(imports[i]);
      }
    }
    return importList;
  }

  static ClassElement getTypeFromParts(
      String className,
      CompilationUnitElement definingCompilationUnit,
      List<CompilationUnitElement> parts) {
    ClassElement type = definingCompilationUnit.getType(className);
    if (type != null) {
      return type;
    }
    for (CompilationUnitElement part in parts) {
      type = part.getType(className);
      if (type != null) {
        return type;
      }
    }
    return null;
  }

  /// Return `true` if the [library] has the given [capability].
  static bool hasResolutionCapability(
      LibraryElement library, LibraryResolutionCapability capability) {
    return library is LibraryElementImpl &&
        BooleanArray.get(library._resolutionCapabilities, capability.index);
  }
}

/// Enum of possible resolution capabilities that a [LibraryElementImpl] has.
enum LibraryResolutionCapability {
  /// All elements have their types resolved.
  resolvedTypeNames,

  /// All (potentially) constants expressions are set into corresponding
  /// elements.
  constantExpressions,
}

/// A concrete implementation of a [LocalVariableElement].
class LocalVariableElementImpl extends NonParameterVariableElementImpl
    implements LocalVariableElement {
  /// Initialize a newly created method element to have the given [name] and
  /// [offset].
  LocalVariableElementImpl(String name, int offset) : super(name, offset);

  /// Initialize a newly created local variable element to have the given
  /// [name].
  LocalVariableElementImpl.forNode(Identifier name) : super.forNode(name);

  @override
  String get identifier {
    return '$name$nameOffset';
  }

  @override
  bool get isLate {
    return hasModifier(Modifier.LATE);
  }

  /// Set whether this variable is late.
  void set isLate(bool isLate) {
    setModifier(Modifier.LATE, isLate);
  }

  @override
  ElementKind get kind => ElementKind.LOCAL_VARIABLE;

  @override
  T accept<T>(ElementVisitor<T> visitor) =>
      visitor.visitLocalVariableElement(this);

  @override
  void appendTo(StringBuffer buffer) {
    buffer.write(type);
    buffer.write(" ");
    buffer.write(displayName);
  }
}

/// A concrete implementation of a [MethodElement].
class MethodElementImpl extends ExecutableElementImpl implements MethodElement {
  /// Initialize a newly created method element to have the given [name] at the
  /// given [offset].
  MethodElementImpl(String name, int offset) : super(name, offset);

  MethodElementImpl.forLinkedNode(TypeParameterizedElementMixin enclosingClass,
      Reference reference, MethodDeclaration linkedNode)
      : super.forLinkedNode(enclosingClass, reference, linkedNode);

  /// Initialize a newly created method element to have the given [name].
  MethodElementImpl.forNode(Identifier name) : super.forNode(name);

  @override
  String get displayName {
    String displayName = super.displayName;
    if ("unary-" == displayName) {
      return "-";
    }
    return displayName;
  }

  /// Set whether this class is abstract.
  void set isAbstract(bool isAbstract) {
    setModifier(Modifier.ABSTRACT, isAbstract);
  }

  @override
  bool get isOperator {
    String name = displayName;
    if (name.isEmpty) {
      return false;
    }
    int first = name.codeUnitAt(0);
    return !((0x61 <= first && first <= 0x7A) ||
        (0x41 <= first && first <= 0x5A) ||
        first == 0x5F ||
        first == 0x24);
  }

  @override
  bool get isStatic {
    if (linkedNode != null) {
      return enclosingUnit.linkedContext.isStatic(linkedNode);
    }
    return hasModifier(Modifier.STATIC);
  }

  /// Set whether this method is static.
  void set isStatic(bool isStatic) {
    setModifier(Modifier.STATIC, isStatic);
  }

  @override
  ElementKind get kind => ElementKind.METHOD;

  @override
  String get name {
    String name = super.name;
    if (name == '-' && parameters.isEmpty) {
      return 'unary-';
    }
    return super.name;
  }

  @override
  T accept<T>(ElementVisitor<T> visitor) => visitor.visitMethodElement(this);
}

/// A [ClassElementImpl] representing a mixin declaration.
class MixinElementImpl extends ClassElementImpl {
  // TODO(brianwilkerson) Consider creating an abstract superclass of
  // ClassElementImpl that contains the portions of the API that this class
  // needs, and make this class extend the new class.

  /// A list containing all of the superclass constraints that are defined for
  /// the mixin.
  List<InterfaceType> _superclassConstraints;

  /// Names of methods, getters, setters, and operators that this mixin
  /// declaration super-invokes.  For setters this includes the trailing "=".
  /// The list will be empty if this class is not a mixin declaration.
  List<String> _superInvokedNames;

  /// Initialize a newly created class element to have the given [name] at the
  /// given [offset] in the file that contains the declaration of this element.
  MixinElementImpl(String name, int offset) : super(name, offset);

  MixinElementImpl.forLinkedNode(CompilationUnitElementImpl enclosing,
      Reference reference, MixinDeclaration linkedNode)
      : super.forLinkedNode(enclosing, reference, linkedNode);

  /// Initialize a newly created class element to have the given [name].
  MixinElementImpl.forNode(Identifier name) : super.forNode(name);

  @override
  bool get isAbstract => true;

  @override
  bool get isMixin => true;

  @override
  List<InterfaceType> get mixins => const <InterfaceType>[];

  @override
  List<InterfaceType> get superclassConstraints {
    if (_superclassConstraints != null) return _superclassConstraints;

    if (linkedNode != null) {
      List<InterfaceType> constraints;
      var onClause = enclosingUnit.linkedContext.getOnClause(linkedNode);
      if (onClause != null) {
        constraints = onClause.superclassConstraints
            .map((node) => node.type)
            .whereType<InterfaceType>()
            .where(_isInterfaceTypeInterface)
            .toList();
      }
      if (constraints == null || constraints.isEmpty) {
        constraints = [context.typeProvider.objectType];
      }
      return _superclassConstraints = constraints;
    }

    return _superclassConstraints ?? const <InterfaceType>[];
  }

  void set superclassConstraints(List<InterfaceType> superclassConstraints) {
    _superclassConstraints = superclassConstraints;
  }

  @override
  List<String> get superInvokedNames {
    if (_superInvokedNames != null) return _superInvokedNames;

    if (linkedNode != null) {
      return _superInvokedNames =
          linkedContext.getMixinSuperInvokedNames(linkedNode);
    }

    return _superInvokedNames ?? const <String>[];
  }

  void set superInvokedNames(List<String> superInvokedNames) {
    _superInvokedNames = superInvokedNames;
  }

  @override
  InterfaceType get supertype => null;

  @override
  void set supertype(InterfaceType supertype) {
    throw new StateError('Attempt to set a supertype for a mixin declaratio.');
  }

  @override
  void appendTo(StringBuffer buffer) {
    buffer.write('mixin ');
    String name = displayName;
    if (name == null) {
      // TODO(brianwilkerson) Can this happen (for either classes or mixins)?
      buffer.write("{unnamed mixin}");
    } else {
      buffer.write(name);
    }
    int variableCount = typeParameters.length;
    if (variableCount > 0) {
      buffer.write("<");
      for (int i = 0; i < variableCount; i++) {
        if (i > 0) {
          buffer.write(", ");
        }
        (typeParameters[i] as TypeParameterElementImpl).appendTo(buffer);
      }
      buffer.write(">");
    }
    if (superclassConstraints.isNotEmpty) {
      buffer.write(' on ');
      buffer.write(superclassConstraints.map((t) => t.displayName).join(', '));
    }
    if (interfaces.isNotEmpty) {
      buffer.write(' implements ');
      buffer.write(interfaces.map((t) => t.displayName).join(', '));
    }
  }
}

/// The constants for all of the modifiers defined by the Dart language and for
/// a few additional flags that are useful.
///
/// Clients may not extend, implement or mix-in this class.
class Modifier implements Comparable<Modifier> {
  /// Indicates that the modifier 'abstract' was applied to the element.
  static const Modifier ABSTRACT = const Modifier('ABSTRACT', 0);

  /// Indicates that an executable element has a body marked as being
  /// asynchronous.
  static const Modifier ASYNCHRONOUS = const Modifier('ASYNCHRONOUS', 1);

  /// Indicates that the modifier 'const' was applied to the element.
  static const Modifier CONST = const Modifier('CONST', 2);

  /// Indicates that the modifier 'covariant' was applied to the element.
  static const Modifier COVARIANT = const Modifier('COVARIANT', 3);

  /// Indicates that the import element represents a deferred library.
  static const Modifier DEFERRED = const Modifier('DEFERRED', 4);

  /// Indicates that a class element was defined by an enum declaration.
  static const Modifier ENUM = const Modifier('ENUM', 5);

  /// Indicates that a class element was defined by an enum declaration.
  static const Modifier EXTERNAL = const Modifier('EXTERNAL', 6);

  /// Indicates that the modifier 'factory' was applied to the element.
  static const Modifier FACTORY = const Modifier('FACTORY', 7);

  /// Indicates that the modifier 'final' was applied to the element.
  static const Modifier FINAL = const Modifier('FINAL', 8);

  /// Indicates that an executable element has a body marked as being a
  /// generator.
  static const Modifier GENERATOR = const Modifier('GENERATOR', 9);

  /// Indicates that the pseudo-modifier 'get' was applied to the element.
  static const Modifier GETTER = const Modifier('GETTER', 10);

  /// A flag used for libraries indicating that the defining compilation unit
  /// contains at least one import directive whose URI uses the "dart-ext"
  /// scheme.
  static const Modifier HAS_EXT_URI = const Modifier('HAS_EXT_URI', 11);

  /// Indicates that the associated element did not have an explicit type
  /// associated with it. If the element is an [ExecutableElement], then the
  /// type being referred to is the return type.
  static const Modifier IMPLICIT_TYPE = const Modifier('IMPLICIT_TYPE', 12);

  /// Indicates that modifier 'lazy' was applied to the element.
  static const Modifier LATE = const Modifier('LATE', 13);

  /// Indicates that a class is a mixin application.
  static const Modifier MIXIN_APPLICATION =
      const Modifier('MIXIN_APPLICATION', 14);

  /// Indicates that a class contains an explicit reference to 'super'.
  static const Modifier REFERENCES_SUPER =
      const Modifier('REFERENCES_SUPER', 15);

  /// Indicates that the pseudo-modifier 'set' was applied to the element.
  static const Modifier SETTER = const Modifier('SETTER', 16);

  /// Indicates that the modifier 'static' was applied to the element.
  static const Modifier STATIC = const Modifier('STATIC', 17);

  /// Indicates that the element does not appear in the source code but was
  /// implicitly created. For example, if a class does not define any
  /// constructors, an implicit zero-argument constructor will be created and it
  /// will be marked as being synthetic.
  static const Modifier SYNTHETIC = const Modifier('SYNTHETIC', 18);

  static const List<Modifier> values = const [
    ABSTRACT,
    ASYNCHRONOUS,
    CONST,
    COVARIANT,
    DEFERRED,
    ENUM,
    EXTERNAL,
    FACTORY,
    FINAL,
    GENERATOR,
    GETTER,
    HAS_EXT_URI,
    IMPLICIT_TYPE,
    LATE,
    MIXIN_APPLICATION,
    REFERENCES_SUPER,
    SETTER,
    STATIC,
    SYNTHETIC
  ];

  /// The name of this modifier.
  final String name;

  /// The ordinal value of the modifier.
  final int ordinal;

  const Modifier(this.name, this.ordinal);

  @override
  int get hashCode => ordinal;

  @override
  int compareTo(Modifier other) => ordinal - other.ordinal;

  @override
  String toString() => name;
}

/// A concrete implementation of a [MultiplyDefinedElement].
class MultiplyDefinedElementImpl implements MultiplyDefinedElement {
  /// The unique integer identifier of this element.
  final int id = ElementImpl._NEXT_ID++;

  /// The analysis context in which the multiply defined elements are defined.
  @override
  final AnalysisContext context;

  @override
  final AnalysisSession session;

  /// The name of the conflicting elements.
  @override
  final String name;

  @override
  final List<Element> conflictingElements;

  /// Initialize a newly created element in the given [context] to represent
  /// the given non-empty [conflictingElements].
  MultiplyDefinedElementImpl(
      this.context, this.session, this.name, this.conflictingElements);

  @override
  String get displayName => name;

  @override
  String get documentationComment => null;

  @override
  Element get enclosingElement => null;

  @override
  bool get hasAlwaysThrows => false;

  @override
  bool get hasDeprecated => false;

  @override
  bool get hasFactory => false;

  @override
  bool get hasIsTest => false;

  @override
  bool get hasIsTestGroup => false;

  @override
  bool get hasJS => false;

  @override
  bool get hasLiteral => false;

  @override
  bool get hasMustCallSuper => false;

  @override
  bool get hasNonVirtual => false;

  @override
  bool get hasOptionalTypeArgs => false;

  @override
  bool get hasOverride => false;

  @override
  bool get hasProtected => false;

  @override
  bool get hasRequired => false;

  @override
  bool get hasSealed => false;

  @override
  bool get hasVisibleForTemplate => false;

  @override
  bool get hasVisibleForTesting => false;

  @override
  bool get isPrivate {
    String name = displayName;
    if (name == null) {
      return false;
    }
    return Identifier.isPrivateName(name);
  }

  @override
  bool get isPublic => !isPrivate;

  @override
  bool get isSynthetic => true;

  bool get isVisibleForTemplate => false;

  @override
  ElementKind get kind => ElementKind.ERROR;

  @override
  LibraryElement get library => null;

  @override
  Source get librarySource => null;

  @override
  ElementLocation get location => null;

  @override
  List<ElementAnnotation> get metadata => const <ElementAnnotation>[];

  @override
  int get nameLength => displayName != null ? displayName.length : 0;

  @override
  int get nameOffset => -1;

  @override
  Source get source => null;

  @override
  DartType get type => DynamicTypeImpl.instance;

  @override
  T accept<T>(ElementVisitor<T> visitor) =>
      visitor.visitMultiplyDefinedElement(this);

  @override
  E getAncestor<E extends Element>(Predicate<Element> predicate) => null;

  @override
  String getExtendedDisplayName(String shortName) {
    if (shortName != null) {
      return shortName;
    }
    return displayName;
  }

  @override
  bool isAccessibleIn(LibraryElement library) {
    for (Element element in conflictingElements) {
      if (element.isAccessibleIn(library)) {
        return true;
      }
    }
    return false;
  }

  @override
  String toString() {
    StringBuffer buffer = new StringBuffer();
    bool needsSeparator = false;
    void writeList(List<Element> elements) {
      for (Element element in elements) {
        if (needsSeparator) {
          buffer.write(", ");
        } else {
          needsSeparator = true;
        }
        if (element is ElementImpl) {
          element.appendTo(buffer);
        } else {
          buffer.write(element);
        }
      }
    }

    buffer.write("[");
    writeList(conflictingElements);
    buffer.write("]");
    return buffer.toString();
  }

  @override
  void visitChildren(ElementVisitor visitor) {
    // There are no children to visit
  }
}

/// The synthetic element representing the declaration of the type `Never`.
class NeverElementImpl extends ElementImpl implements TypeDefiningElement {
  /// Return the unique instance of this class.
  static NeverElementImpl get instance =>
      BottomTypeImpl.instance.element as NeverElementImpl;

  /// Initialize a newly created instance of this class. Instances of this class
  /// should <b>not</b> be created except as part of creating the type
  /// associated with this element. The single instance of this class should be
  /// accessed through the method [instance].
  NeverElementImpl() : super('Never', -1) {
    setModifier(Modifier.SYNTHETIC, true);
  }

  @override
  ElementKind get kind => ElementKind.NEVER;

  @override
  DartType get type {
    throw StateError('Should not be accessed.');
  }

  @override
  T accept<T>(ElementVisitor<T> visitor) => null;

  DartType instantiate({
    @required NullabilitySuffix nullabilitySuffix,
  }) {
    switch (nullabilitySuffix) {
      case NullabilitySuffix.question:
        return BottomTypeImpl.instanceNullable;
      case NullabilitySuffix.star:
        return BottomTypeImpl.instanceLegacy;
      case NullabilitySuffix.none:
        return BottomTypeImpl.instance;
    }
    throw StateError('Unsupported nullability: $nullabilitySuffix');
  }
}

/// A [VariableElementImpl], which is not a parameter.
abstract class NonParameterVariableElementImpl extends VariableElementImpl {
  /// Initialize a newly created variable element to have the given [name] and
  /// [offset].
  NonParameterVariableElementImpl(String name, int offset)
      : super(name, offset);

  NonParameterVariableElementImpl.forLinkedNode(
      ElementImpl enclosing, Reference reference, AstNode linkedNode)
      : super.forLinkedNode(enclosing, reference, linkedNode);

  /// Initialize a newly created variable element to have the given [name].
  NonParameterVariableElementImpl.forNode(Identifier name)
      : super.forNode(name);

  @override
  int get codeLength {
    if (linkedNode != null) {
      return linkedContext.getCodeLength(linkedNode);
    }
    return super.codeLength;
  }

  @override
  int get codeOffset {
    if (linkedNode != null) {
      return linkedContext.getCodeOffset(linkedNode);
    }
    return super.codeOffset;
  }

  @override
  String get documentationComment {
    if (linkedNode != null) {
      var context = enclosingUnit.linkedContext;
      var comment = context.getDocumentationComment(linkedNode);
      return getCommentNodeRawText(comment);
    }
    return super.documentationComment;
  }

  @override
  bool get hasImplicitType {
    if (linkedNode != null) {
      return linkedContext.hasImplicitType(linkedNode);
    }
    return super.hasImplicitType;
  }

  @override
  void set hasImplicitType(bool hasImplicitType) {
    super.hasImplicitType = hasImplicitType;
  }

  @override
  FunctionElement get initializer {
    if (_initializer == null) {
      if (linkedNode != null) {
        if (linkedContext.hasInitializer(linkedNode)) {
          _initializer = new FunctionElementImpl('', -1)
            ..isSynthetic = true
            .._type = FunctionTypeImpl.synthetic(type, [], [],
                nullabilitySuffix: NullabilitySuffix.star)
            ..enclosingElement = this;
        }
      }
    }
    return super.initializer;
  }

  @override
  String get name {
    if (linkedNode != null) {
      return reference.name;
    }
    return super.name;
  }

  @override
  int get nameOffset {
    if (linkedNode != null) {
      return enclosingUnit.linkedContext.getNameOffset(linkedNode);
    }

    return super.nameOffset;
  }

  @override
  void set type(DartType type) {
    if (linkedNode != null) {
      return linkedContext.setVariableType(linkedNode, type);
    }
    _type = _checkElementOfType(type);
  }

  @override
  TopLevelInferenceError get typeInferenceError {
    if (linkedNode != null) {
      return linkedContext.getTypeInferenceError(linkedNode);
    }

    // We don't support type inference errors without linking.
    return null;
  }
}

/// A concrete implementation of a [ParameterElement].
class ParameterElementImpl extends VariableElementImpl
    with ParameterElementMixin
    implements ParameterElement {
  /// A list containing all of the parameters defined by this parameter element.
  /// There will only be parameters if this parameter is a function typed
  /// parameter.
  List<ParameterElement> _parameters;

  /// A list containing all of the type parameters defined for this parameter
  /// element. There will only be parameters if this parameter is a function
  /// typed parameter.
  List<TypeParameterElement> _typeParameters;

  /// The kind of this parameter.
  ParameterKind _parameterKind;

  /// The Dart code of the default value.
  String _defaultValueCode;

  bool _inheritsCovariant = false;

  /// Initialize a newly created parameter element to have the given [name] and
  /// [nameOffset].
  ParameterElementImpl(String name, int nameOffset) : super(name, nameOffset);

  ParameterElementImpl.forLinkedNode(
      ElementImpl enclosing, Reference reference, FormalParameter linkedNode)
      : super.forLinkedNode(enclosing, reference, linkedNode);

  factory ParameterElementImpl.forLinkedNodeFactory(
      ElementImpl enclosing, Reference reference, FormalParameter node) {
    if (node is FieldFormalParameter) {
      return FieldFormalParameterElementImpl.forLinkedNode(
        enclosing,
        reference,
        node,
      );
    } else if (node is FunctionTypedFormalParameter ||
        node is SimpleFormalParameter) {
      return ParameterElementImpl.forLinkedNode(enclosing, reference, node);
    } else {
      throw UnimplementedError('${node.runtimeType}');
    }
  }

  /// Initialize a newly created parameter element to have the given [name].
  ParameterElementImpl.forNode(Identifier name) : super.forNode(name);

  /// Creates a synthetic parameter with [name], [type] and [kind].
  factory ParameterElementImpl.synthetic(
      String name, DartType type, ParameterKind kind) {
    ParameterElementImpl element = new ParameterElementImpl(name, -1);
    element.type = type;
    element.isSynthetic = true;
    element.parameterKind = kind;
    return element;
  }

  @override
  int get codeLength {
    if (linkedNode != null) {
      return linkedContext.getCodeLength(linkedNode);
    }
    return super.codeLength;
  }

  @override
  int get codeOffset {
    if (linkedNode != null) {
      return linkedContext.getCodeOffset(linkedNode);
    }
    return super.codeOffset;
  }

  @override
  String get defaultValueCode {
    if (linkedNode != null) {
      return linkedContext.getDefaultValueCode(linkedNode);
    }

    return _defaultValueCode;
  }

  /// Set Dart code of the default value.
  void set defaultValueCode(String defaultValueCode) {
    this._defaultValueCode = StringUtilities.intern(defaultValueCode);
  }

  @override
  bool get hasImplicitType {
    if (linkedNode != null) {
      return linkedContext.hasImplicitType(linkedNode);
    }
    return super.hasImplicitType;
  }

  @override
  void set hasImplicitType(bool hasImplicitType) {
    super.hasImplicitType = hasImplicitType;
  }

  /// True if this parameter inherits from a covariant parameter. This happens
  /// when it overrides a method in a supertype that has a corresponding
  /// covariant parameter.
  bool get inheritsCovariant {
    if (linkedNode != null) {
      return linkedContext.getInheritsCovariant(linkedNode);
    }
    return _inheritsCovariant;
  }

  /// Record whether or not this parameter inherits from a covariant parameter.
  void set inheritsCovariant(bool value) {
    if (linkedNode != null) {
      linkedContext.setInheritsCovariant(linkedNode, value);
      return;
    }
    _inheritsCovariant = value;
  }

  @override
  FunctionElement get initializer {
    if (_initializer != null) return _initializer;

    if (linkedNode != null) {
      if (linkedContext.hasDefaultValue(linkedNode)) {
        _initializer = FunctionElementImpl('', -1)
          ..enclosingElement = this
          ..isSynthetic = true;
      }
    }

    return super.initializer;
  }

  /// Set the function representing this variable's initializer to the given
  /// [function].
  void set initializer(FunctionElement function) {
    super.initializer = function;
  }

  @override
  bool get isCovariant {
    if (isExplicitlyCovariant || inheritsCovariant) {
      return true;
    }
    return false;
  }

  /// Return true if this parameter is explicitly marked as being covariant.
  bool get isExplicitlyCovariant {
    if (linkedNode != null) {
      return linkedContext.isExplicitlyCovariant(linkedNode);
    }
    return hasModifier(Modifier.COVARIANT);
  }

  /// Set whether this variable parameter is explicitly marked as being
  /// covariant.
  void set isExplicitlyCovariant(bool isCovariant) {
    setModifier(Modifier.COVARIANT, isCovariant);
  }

  @override
  bool get isFinal {
    if (linkedNode != null) {
      FormalParameter linkedNode = this.linkedNode;
      return linkedNode.isFinal;
    }
    return super.isFinal;
  }

  @override
  bool get isInitializingFormal => false;

  @override
  bool get isLate => false;

  @override
  ElementKind get kind => ElementKind.PARAMETER;

  @override
  String get name {
    if (linkedNode != null) {
      return reference.name;
    }
    return super.name;
  }

  @override
  int get nameOffset {
    if (linkedNode != null) {
      return enclosingUnit.linkedContext.getNameOffset(linkedNode);
    }

    return super.nameOffset;
  }

  @override
  ParameterKind get parameterKind {
    if (_parameterKind != null) return _parameterKind;

    if (linkedNode != null) {
      FormalParameter linkedNode = this.linkedNode;
      // ignore: deprecated_member_use_from_same_package
      return linkedNode.kind;
    }
    return _parameterKind;
  }

  void set parameterKind(ParameterKind parameterKind) {
    _parameterKind = parameterKind;
  }

  @override
  List<ParameterElement> get parameters {
    if (_parameters != null) return _parameters;

    if (linkedNode != null) {
      var context = enclosingUnit.linkedContext;
      var formalParameters = context.getFormalParameters(linkedNode);
      if (formalParameters != null) {
        var containerRef = reference.getChild('@parameter');
        return _parameters = ParameterElementImpl.forLinkedNodeList(
          this,
          context,
          containerRef,
          formalParameters,
        );
      } else {
        return _parameters ??= const <ParameterElement>[];
      }
    }

    return _parameters ??= const <ParameterElement>[];
  }

  /// Set the parameters defined by this executable element to the given
  /// [parameters].
  void set parameters(List<ParameterElement> parameters) {
    for (ParameterElement parameter in parameters) {
      (parameter as ParameterElementImpl).enclosingElement = this;
    }
    this._parameters = parameters;
  }

  @override
  DartType get type {
    if (linkedNode != null) {
      if (_type != null) return _type;
      var context = enclosingUnit.linkedContext;
      return _type = context.getType(linkedNode);
    }
    return super.type;
  }

  @override
  TopLevelInferenceError get typeInferenceError {
    if (linkedNode != null) {
      return linkedContext.getTypeInferenceError(linkedNode);
    }

    // We don't support type inference errors without linking.
    return null;
  }

  @override
  List<TypeParameterElement> get typeParameters {
    if (_typeParameters != null) return _typeParameters;

    if (linkedNode != null) {
      var typeParameters = linkedContext.getTypeParameters2(linkedNode);
      if (typeParameters == null) {
        return _typeParameters = const [];
      }
      var containerRef = reference.getChild('@typeParameter');
      return _typeParameters =
          typeParameters.typeParameters.map<TypeParameterElement>((node) {
        var reference = containerRef.getChild(node.name.name);
        if (reference.hasElementFor(node)) {
          return reference.element as TypeParameterElement;
        }
        return TypeParameterElementImpl.forLinkedNode(this, reference, node);
      }).toList();
    }

    return _typeParameters ??= const <TypeParameterElement>[];
  }

  /// Set the type parameters defined by this parameter element to the given
  /// [typeParameters].
  void set typeParameters(List<TypeParameterElement> typeParameters) {
    for (TypeParameterElement parameter in typeParameters) {
      (parameter as TypeParameterElementImpl).enclosingElement = this;
    }
    this._typeParameters = typeParameters;
  }

  @override
  T accept<T>(ElementVisitor<T> visitor) => visitor.visitParameterElement(this);

  @override
  void appendTo(StringBuffer buffer) {
    if (isNamed) {
      buffer.write('{');
      if (isRequiredNamed) {
        buffer.write('required ');
      }
      appendToWithoutDelimiters(buffer);
      buffer.write('}');
    } else if (isOptionalPositional) {
      buffer.write('[');
      appendToWithoutDelimiters(buffer);
      buffer.write(']');
    } else {
      appendToWithoutDelimiters(buffer);
    }
  }

  @override
  void visitChildren(ElementVisitor visitor) {
    super.visitChildren(visitor);
    safelyVisitChildren(parameters, visitor);
  }

  static List<ParameterElement> forLinkedNodeList(
      ElementImpl enclosing,
      LinkedUnitContext context,
      Reference containerRef,
      List<FormalParameter> formalParameters) {
    if (formalParameters == null) {
      return const [];
    }

    return formalParameters.map((node) {
      if (node is DefaultFormalParameter) {
        NormalFormalParameter parameterNode = node.parameter;
        var name = parameterNode.identifier?.name ?? '';
        var reference = containerRef.getChild(name);
        reference.node = node;
        if (parameterNode is FieldFormalParameter) {
          return DefaultFieldFormalParameterElementImpl.forLinkedNode(
            enclosing,
            reference,
            node,
          );
        } else {
          return DefaultParameterElementImpl.forLinkedNode(
            enclosing,
            reference,
            node,
          );
        }
      } else {
        if (node.identifier == null) {
          return ParameterElementImpl.forLinkedNodeFactory(
            enclosing,
            containerRef.getChild(''),
            node,
          );
        } else {
          var name = node.identifier.name;
          var reference = containerRef.getChild(name);
          if (reference.hasElementFor(node)) {
            return reference.element as ParameterElement;
          }
          return ParameterElementImpl.forLinkedNodeFactory(
            enclosing,
            reference,
            node,
          );
        }
      }
    }).toList();
  }
}

/// The parameter of an implicit setter.
class ParameterElementImpl_ofImplicitSetter extends ParameterElementImpl {
  final PropertyAccessorElementImpl_ImplicitSetter setter;

  ParameterElementImpl_ofImplicitSetter(
      PropertyAccessorElementImpl_ImplicitSetter setter)
      : setter = setter,
        super('_${setter.variable.name}', setter.variable.nameOffset) {
    enclosingElement = setter;
    isSynthetic = true;
    parameterKind = ParameterKind.REQUIRED;
  }

  @override
  bool get inheritsCovariant {
    PropertyInducingElement variable = setter.variable;
    if (variable is FieldElementImpl) {
      if (variable.linkedNode != null) {
        var context = variable.linkedContext;
        return context.getInheritsCovariant(variable.linkedNode);
      }
    }
    return false;
  }

  @override
  void set inheritsCovariant(bool value) {
    PropertyInducingElement variable = setter.variable;
    if (variable is FieldElementImpl) {
      if (variable.linkedNode != null) {
        var context = variable.linkedContext;
        return context.setInheritsCovariant(variable.linkedNode, value);
      }
    }
  }

  @override
  bool get isCovariant {
    if (isExplicitlyCovariant || inheritsCovariant) {
      return true;
    }
    return false;
  }

  @override
  bool get isExplicitlyCovariant {
    PropertyInducingElement variable = setter.variable;
    if (variable is FieldElementImpl) {
      return variable.isCovariant;
    }
    return false;
  }

  @override
  DartType get type => setter.variable.type;

  @override
  void set type(DartType type) {
    assert(false); // Should never be called.
  }
}

/// A mixin that provides a common implementation for methods defined in
/// [ParameterElement].
mixin ParameterElementMixin implements ParameterElement {
  @override
  bool get isNamed =>
      parameterKind == ParameterKind.NAMED ||
      parameterKind == ParameterKind.NAMED_REQUIRED;

  @override
  bool get isNotOptional =>
      parameterKind == ParameterKind.REQUIRED ||
      parameterKind == ParameterKind.NAMED_REQUIRED;

  @override
  bool get isOptional =>
      parameterKind == ParameterKind.NAMED ||
      parameterKind == ParameterKind.POSITIONAL;

  @override
  bool get isOptionalNamed => parameterKind == ParameterKind.NAMED;

  @override
  bool get isOptionalPositional => parameterKind == ParameterKind.POSITIONAL;

  @override
  bool get isPositional =>
      parameterKind == ParameterKind.POSITIONAL ||
      parameterKind == ParameterKind.REQUIRED;

  @override
  bool get isRequiredNamed => parameterKind == ParameterKind.NAMED_REQUIRED;

  @override
  bool get isRequiredPositional => parameterKind == ParameterKind.REQUIRED;

  @override
  // Overridden to remove the 'deprecated' annotation.
  ParameterKind get parameterKind;

  @override
  void appendToWithoutDelimiters(StringBuffer buffer) {
    buffer.write(type);
    buffer.write(' ');
    buffer.write(displayName);
    if (defaultValueCode != null) {
      buffer.write(' = ');
      buffer.write(defaultValueCode);
    }
  }
}

/// A concrete implementation of a [PrefixElement].
class PrefixElementImpl extends ElementImpl implements PrefixElement {
  /// Initialize a newly created method element to have the given [name] and
  /// [nameOffset].
  PrefixElementImpl(String name, int nameOffset) : super(name, nameOffset);

  PrefixElementImpl.forLinkedNode(
      ElementImpl enclosing, Reference reference, SimpleIdentifier linkedNode)
      : super.forLinkedNode(enclosing, reference, linkedNode);

  /// Initialize a newly created prefix element to have the given [name].
  PrefixElementImpl.forNode(Identifier name) : super.forNode(name);

  @override
  String get displayName => name;

  @override
  LibraryElement get enclosingElement =>
      super.enclosingElement as LibraryElement;

  @override
  ElementKind get kind => ElementKind.PREFIX;

  @override
  String get name {
    if (linkedNode != null) {
      return reference.name;
    }
    return super.name;
  }

  @override
  int get nameOffset {
    if (linkedNode != null) {
      return (linkedNode as SimpleIdentifier).offset;
    }
    return super.nameOffset;
  }

  @override
  T accept<T>(ElementVisitor<T> visitor) => visitor.visitPrefixElement(this);

  @override
  void appendTo(StringBuffer buffer) {
    buffer.write("as ");
    super.appendTo(buffer);
  }
}

/// A concrete implementation of a [PropertyAccessorElement].
class PropertyAccessorElementImpl extends ExecutableElementImpl
    implements PropertyAccessorElement {
  /// The variable associated with this accessor.
  PropertyInducingElement variable;

  /// Initialize a newly created property accessor element to have the given
  /// [name] and [offset].
  PropertyAccessorElementImpl(String name, int offset) : super(name, offset);

  PropertyAccessorElementImpl.forLinkedNode(
      ElementImpl enclosing, Reference reference, AstNode linkedNode)
      : super.forLinkedNode(enclosing, reference, linkedNode);

  /// Initialize a newly created property accessor element to have the given
  /// [name].
  PropertyAccessorElementImpl.forNode(Identifier name) : super.forNode(name);

  /// Initialize a newly created synthetic property accessor element to be
  /// associated with the given [variable].
  PropertyAccessorElementImpl.forVariable(PropertyInducingElementImpl variable,
      {Reference reference})
      : super(variable.name, variable.nameOffset, reference: reference) {
    this.variable = variable;
    isStatic = variable.isStatic;
    isSynthetic = true;
  }

  @override
  PropertyAccessorElement get correspondingGetter {
    if (isGetter || variable == null) {
      return null;
    }
    return variable.getter;
  }

  @override
  PropertyAccessorElement get correspondingSetter {
    if (isSetter || variable == null) {
      return null;
    }
    return variable.setter;
  }

  /// Set whether this accessor is a getter.
  void set getter(bool isGetter) {
    setModifier(Modifier.GETTER, isGetter);
  }

  @override
  String get identifier {
    String name = displayName;
    String suffix = isGetter ? "?" : "=";
    return "$name$suffix";
  }

  /// Set whether this class is abstract.
  void set isAbstract(bool isAbstract) {
    setModifier(Modifier.ABSTRACT, isAbstract);
  }

  @override
  bool get isGetter {
    if (linkedNode != null) {
      return enclosingUnit.linkedContext.isGetter(linkedNode);
    }
    return hasModifier(Modifier.GETTER);
  }

  @override
  bool get isSetter {
    if (linkedNode != null) {
      return enclosingUnit.linkedContext.isSetter(linkedNode);
    }
    return hasModifier(Modifier.SETTER);
  }

  @override
  bool get isStatic {
    if (linkedNode != null) {
      return enclosingUnit.linkedContext.isStatic(linkedNode);
    }
    return hasModifier(Modifier.STATIC);
  }

  /// Set whether this accessor is static.
  void set isStatic(bool isStatic) {
    setModifier(Modifier.STATIC, isStatic);
  }

  @override
  ElementKind get kind {
    if (isGetter) {
      return ElementKind.GETTER;
    }
    return ElementKind.SETTER;
  }

  @override
  String get name {
    if (linkedNode != null) {
      var name = reference.name;
      if (isSetter) {
        return '$name=';
      }
      return name;
    }
    if (isSetter) {
      return "${super.name}=";
    }
    return super.name;
  }

  /// Set whether this accessor is a setter.
  void set setter(bool isSetter) {
    setModifier(Modifier.SETTER, isSetter);
  }

  @override
  T accept<T>(ElementVisitor<T> visitor) =>
      visitor.visitPropertyAccessorElement(this);

  @override
  void appendTo(StringBuffer buffer) {
    super.appendToWithName(
        buffer, (isGetter ? 'get ' : 'set ') + variable.displayName);
  }
}

/// Implicit getter for a [PropertyInducingElementImpl].
class PropertyAccessorElementImpl_ImplicitGetter
    extends PropertyAccessorElementImpl {
  /// Create the implicit getter and bind it to the [property].
  PropertyAccessorElementImpl_ImplicitGetter(
      PropertyInducingElementImpl property,
      {Reference reference})
      : super.forVariable(property, reference: reference) {
    property.getter = this;
    enclosingElement = property.enclosingElement;
  }

  @override
  bool get hasImplicitReturnType => variable.hasImplicitType;

  @override
  bool get isGetter => true;

  @override
  DartType get returnType => variable.type;

  @override
  void set returnType(DartType returnType) {
    assert(false); // Should never be called.
  }

  @override
  FunctionType get type {
    if (_type != null) return _type;

    // TODO(scheglov) Remove "element" in the breaking changes branch.
    var type = FunctionTypeImpl.synthetic(
      returnType,
      const <TypeParameterElement>[],
      const <ParameterElement>[],
      element: this,
      nullabilitySuffix: _noneOrStarSuffix,
    );

    // Don't cache, because types change during top-level inference.
    if (enclosingElement != null &&
        linkedContext != null &&
        !linkedContext.isLinking) {
      _type = type;
    }

    return type;
  }

  @override
  void set type(FunctionType type) {
    assert(false); // Should never be called.
  }
}

/// Implicit setter for a [PropertyInducingElementImpl].
class PropertyAccessorElementImpl_ImplicitSetter
    extends PropertyAccessorElementImpl {
  /// Create the implicit setter and bind it to the [property].
  PropertyAccessorElementImpl_ImplicitSetter(
      PropertyInducingElementImpl property,
      {Reference reference})
      : super.forVariable(property, reference: reference) {
    property.setter = this;
    enclosingElement = property.enclosingElement;
  }

  @override
  bool get isSetter => true;

  @override
  List<ParameterElement> get parameters {
    return _parameters ??= <ParameterElement>[
      new ParameterElementImpl_ofImplicitSetter(this)
    ];
  }

  @override
  DartType get returnType => VoidTypeImpl.instance;

  @override
  void set returnType(DartType returnType) {
    assert(false); // Should never be called.
  }

  @override
  FunctionType get type {
    if (_type != null) return _type;

    // TODO(scheglov) Remove "element" in the breaking changes branch.
    var type = FunctionTypeImpl.synthetic(
      returnType,
      const <TypeParameterElement>[],
      parameters,
      element: this,
      nullabilitySuffix: _noneOrStarSuffix,
    );

    // Don't cache, because types change during top-level inference.
    if (enclosingElement != null &&
        linkedContext != null &&
        !linkedContext.isLinking) {
      _type = type;
    }

    return type;
  }

  @override
  void set type(FunctionType type) {
    assert(false); // Should never be called.
  }
}

/// A concrete implementation of a [PropertyInducingElement].
abstract class PropertyInducingElementImpl
    extends NonParameterVariableElementImpl implements PropertyInducingElement {
  /// The getter associated with this element.
  PropertyAccessorElement getter;

  /// The setter associated with this element, or `null` if the element is
  /// effectively `final` and therefore does not have a setter associated with
  /// it.
  PropertyAccessorElement setter;

  /// Initialize a newly created synthetic element to have the given [name] and
  /// [offset].
  PropertyInducingElementImpl(String name, int offset) : super(name, offset);

  PropertyInducingElementImpl.forLinkedNode(
      ElementImpl enclosing, Reference reference, AstNode linkedNode)
      : super.forLinkedNode(enclosing, reference, linkedNode);

  /// Initialize a newly created element to have the given [name].
  PropertyInducingElementImpl.forNode(Identifier name) : super.forNode(name);

  @override
  bool get isConstantEvaluated => true;

  @override
  bool get isLate {
    if (linkedNode != null) {
      return enclosingUnit.linkedContext.isLate(linkedNode);
    }
    return hasModifier(Modifier.LATE);
  }

  @override
  DartType get type {
    if (linkedNode != null) {
      if (_type != null) return _type;
      return _type = linkedContext.getType(linkedNode);
    }
    if (isSynthetic && _type == null) {
      if (getter != null) {
        _type = getter.returnType;
      } else if (setter != null) {
        List<ParameterElement> parameters = setter.parameters;
        _type = parameters.isNotEmpty
            ? parameters[0].type
            : DynamicTypeImpl.instance;
      } else {
        _type = DynamicTypeImpl.instance;
      }
    }
    return super.type;
  }
}

/// A concrete implementation of a [ShowElementCombinator].
class ShowElementCombinatorImpl implements ShowElementCombinator {
  final LinkedUnitContext linkedContext;
  final ShowCombinator linkedNode;

  /// The names that are to be made visible in the importing library if they are
  /// defined in the imported library.
  List<String> _shownNames;

  /// The offset of the character immediately following the last character of
  /// this node.
  int _end = -1;

  /// The offset of the 'show' keyword of this element.
  int _offset = 0;

  ShowElementCombinatorImpl()
      : linkedContext = null,
        linkedNode = null;

  ShowElementCombinatorImpl.forLinkedNode(this.linkedContext, this.linkedNode);

  @override
  int get end {
    if (linkedNode != null) {
      return linkedContext.getCombinatorEnd(linkedNode);
    }
    return _end;
  }

  void set end(int end) {
    _end = end;
  }

  @override
  int get offset {
    if (linkedNode != null) {
      return linkedNode.keyword.offset;
    }
    return _offset;
  }

  void set offset(int offset) {
    _offset = offset;
  }

  @override
  List<String> get shownNames {
    if (_shownNames != null) return _shownNames;

    if (linkedNode != null) {
      return _shownNames = linkedNode.shownNames.map((i) => i.name).toList();
    }

    return _shownNames ?? const <String>[];
  }

  void set shownNames(List<String> shownNames) {
    _shownNames = shownNames;
  }

  @override
  String toString() {
    StringBuffer buffer = new StringBuffer();
    buffer.write("show ");
    int count = shownNames.length;
    for (int i = 0; i < count; i++) {
      if (i > 0) {
        buffer.write(", ");
      }
      buffer.write(shownNames[i]);
    }
    return buffer.toString();
  }
}

/// A concrete implementation of a [TopLevelVariableElement].
class TopLevelVariableElementImpl extends PropertyInducingElementImpl
    implements TopLevelVariableElement {
  /// Initialize a newly created synthetic top-level variable element to have
  /// the given [name] and [offset].
  TopLevelVariableElementImpl(String name, int offset) : super(name, offset);

  TopLevelVariableElementImpl.forLinkedNode(
      ElementImpl enclosing, Reference reference, AstNode linkedNode)
      : super.forLinkedNode(enclosing, reference, linkedNode) {
    if (!linkedNode.isSynthetic) {
      var enclosingRef = enclosing.reference;

      this.getter = PropertyAccessorElementImpl_ImplicitGetter(
        this,
        reference: enclosingRef.getChild('@getter').getChild(name),
      );

      if (!isConst && !isFinal) {
        this.setter = PropertyAccessorElementImpl_ImplicitSetter(
          this,
          reference: enclosingRef.getChild('@setter').getChild(name),
        );
      }
    }
  }

  factory TopLevelVariableElementImpl.forLinkedNodeFactory(
      ElementImpl enclosing, Reference reference, AstNode linkedNode) {
    if (enclosing.enclosingUnit.linkedContext.isConst(linkedNode)) {
      return ConstTopLevelVariableElementImpl.forLinkedNode(
        enclosing,
        reference,
        linkedNode,
      );
    }
    return TopLevelVariableElementImpl.forLinkedNode(
      enclosing,
      reference,
      linkedNode,
    );
  }

  /// Initialize a newly created top-level variable element to have the given
  /// [name].
  TopLevelVariableElementImpl.forNode(Identifier name) : super.forNode(name);

  @override
  bool get isStatic => true;

  @override
  ElementKind get kind => ElementKind.TOP_LEVEL_VARIABLE;

  @override
  T accept<T>(ElementVisitor<T> visitor) =>
      visitor.visitTopLevelVariableElement(this);
}

/// A concrete implementation of a [TypeParameterElement].
class TypeParameterElementImpl extends ElementImpl
    implements TypeParameterElement {
  /// The default value of the type parameter. It is used to provide the
  /// corresponding missing type argument in type annotations and as the
  /// fall-back type value in type inference.
  DartType _defaultType;

  /// The type defined by this type parameter.
  TypeParameterType _type;

  /// The type representing the bound associated with this parameter, or `null`
  /// if this parameter does not have an explicit bound.
  DartType _bound;

  /// Initialize a newly created method element to have the given [name] and
  /// [offset].
  TypeParameterElementImpl(String name, int offset) : super(name, offset);

  TypeParameterElementImpl.forLinkedNode(
      ElementImpl enclosing, Reference reference, TypeParameter linkedNode)
      : super.forLinkedNode(enclosing, reference, linkedNode);

  /// Initialize a newly created type parameter element to have the given
  /// [name].
  TypeParameterElementImpl.forNode(Identifier name) : super.forNode(name);

  /// Initialize a newly created synthetic type parameter element to have the
  /// given [name], and with [synthetic] set to true.
  TypeParameterElementImpl.synthetic(String name) : super(name, -1) {
    isSynthetic = true;
  }

  DartType get bound {
    if (_bound != null) return _bound;

    if (linkedNode != null) {
      var context = enclosingUnit.linkedContext;
      return _bound = context.getTypeParameterBound(linkedNode)?.type;
    }

    return _bound;
  }

  void set bound(DartType bound) {
    _bound = _checkElementOfType(bound);
  }

  @override
  int get codeLength {
    if (linkedNode != null) {
      return linkedContext.getCodeLength(linkedNode);
    }
    return super.codeLength;
  }

  @override
  int get codeOffset {
    if (linkedNode != null) {
      return linkedContext.getCodeOffset(linkedNode);
    }
    return super.codeOffset;
  }

  /// The default value of the type parameter. It is used to provide the
  /// corresponding missing type argument in type annotations and as the
  /// fall-back type value in type inference.
  DartType get defaultType {
    if (_defaultType != null) return _defaultType;

    if (linkedNode != null) {
      return _defaultType = linkedContext.getDefaultType(linkedNode);
    }
    return null;
  }

  set defaultType(DartType defaultType) {
    _defaultType = defaultType;
  }

  @override
  String get displayName => name;

  @override
  ElementKind get kind => ElementKind.TYPE_PARAMETER;

  @override
  String get name {
    if (linkedNode != null) {
      TypeParameter node = this.linkedNode;
      return node.name.name;
    }
    return super.name;
  }

  @override
  int get nameOffset {
    if (linkedNode != null) {
      return enclosingUnit.linkedContext.getNameOffset(linkedNode);
    }

    return super.nameOffset;
  }

  TypeParameterType get type {
    // Note: TypeParameterElement.type has nullability suffix `star` regardless
    // of whether it appears in a migrated library.  This is because for type
    // parameters of synthetic function types, the ancestor chain is broken and
    // we can't find the enclosing library to tell whether it is migrated.
    return _type ??= new TypeParameterTypeImpl(this);
  }

  void set type(TypeParameterType type) {
    _type = type;
  }

  @override
  bool operator ==(Object object) {
    if (identical(this, object)) {
      return true;
    }
    return object is TypeParameterElementImpl && object.location == location;
  }

  @override
  T accept<T>(ElementVisitor<T> visitor) =>
      visitor.visitTypeParameterElement(this);

  @override
  void appendTo(StringBuffer buffer) {
    buffer.write(displayName);
    if (bound != null) {
      buffer.write(" extends ");
      buffer.write(bound);
    }
  }

  @override
  TypeParameterType instantiate({
    @required NullabilitySuffix nullabilitySuffix,
  }) {
    return TypeParameterTypeImpl(this, nullabilitySuffix: nullabilitySuffix);
  }
}

/// Mixin representing an element which can have type parameters.
mixin TypeParameterizedElementMixin
    implements TypeParameterizedElement, ElementImpl {
  /// A cached list containing the type parameters declared by this element
  /// directly, or `null` if the elements have not been created yet. This does
  /// not include type parameters that are declared by any enclosing elements.
  List<TypeParameterElement> _typeParameterElements;

  @override
  bool get isSimplyBounded => true;

  @override
  List<TypeParameterElement> get typeParameters {
    if (_typeParameterElements != null) return _typeParameterElements;

    if (linkedNode != null) {
      var typeParameters = linkedContext.getTypeParameters2(linkedNode);
      if (typeParameters == null) {
        return _typeParameterElements = const [];
      }
      var containerRef = reference.getChild('@typeParameter');
      return _typeParameterElements =
          typeParameters.typeParameters.map<TypeParameterElement>((node) {
        var reference = containerRef.getChild(node.name.name);
        if (reference.hasElementFor(node)) {
          return reference.element as TypeParameterElement;
        }
        return TypeParameterElementImpl.forLinkedNode(this, reference, node);
      }).toList();
    }

    return _typeParameterElements ?? const <TypeParameterElement>[];
  }
}

/// A concrete implementation of a [UriReferencedElement].
abstract class UriReferencedElementImpl extends ElementImpl
    implements UriReferencedElement {
  /// The offset of the URI in the file, or `-1` if this node is synthetic.
  int _uriOffset = -1;

  /// The offset of the character immediately following the last character of
  /// this node's URI, or `-1` if this node is synthetic.
  int _uriEnd = -1;

  /// The URI that is specified by this directive.
  String _uri;

  /// Initialize a newly created import element to have the given [name] and
  /// [offset]. The offset may be `-1` if the element is synthetic.
  UriReferencedElementImpl(String name, int offset) : super(name, offset);

  UriReferencedElementImpl.forLinkedNode(
      ElementImpl enclosing, Reference reference, AstNode linkedNode)
      : super.forLinkedNode(enclosing, reference, linkedNode);

  /// Initialize using the given serialized information.
  UriReferencedElementImpl.forSerialized(ElementImpl enclosingElement)
      : super.forSerialized(enclosingElement);

  /// Return the URI that is specified by this directive.
  String get uri => _uri;

  /// Set the URI that is specified by this directive to be the given [uri].
  void set uri(String uri) {
    _uri = uri;
  }

  /// Return the offset of the character immediately following the last
  /// character of this node's URI, or `-1` if this node is synthetic.
  int get uriEnd => _uriEnd;

  /// Set the offset of the character immediately following the last character
  /// of this node's URI to the given [offset].
  void set uriEnd(int offset) {
    _uriEnd = offset;
  }

  /// Return the offset of the URI in the file, or `-1` if this node is
  /// synthetic.
  int get uriOffset => _uriOffset;

  /// Set the offset of the URI in the file to the given [offset].
  void set uriOffset(int offset) {
    _uriOffset = offset;
  }
}

/// A concrete implementation of a [VariableElement].
abstract class VariableElementImpl extends ElementImpl
    implements VariableElement {
  /// The type of this variable.
  DartType _type;

  /// A synthetic function representing this variable's initializer, or `null
  ///` if this variable does not have an initializer.
  FunctionElement _initializer;

  /// Initialize a newly created variable element to have the given [name] and
  /// [offset].
  VariableElementImpl(String name, int offset) : super(name, offset);

  VariableElementImpl.forLinkedNode(
      ElementImpl enclosing, Reference reference, AstNode linkedNode)
      : super.forLinkedNode(enclosing, reference, linkedNode);

  /// Initialize a newly created variable element to have the given [name].
  VariableElementImpl.forNode(Identifier name) : super.forNode(name);

  /// Initialize using the given serialized information.
  VariableElementImpl.forSerialized(ElementImpl enclosingElement)
      : super.forSerialized(enclosingElement);

  /// If this element represents a constant variable, and it has an initializer,
  /// a copy of the initializer for the constant.  Otherwise `null`.
  ///
  /// Note that in correct Dart code, all constant variables must have
  /// initializers.  However, analyzer also needs to handle incorrect Dart code,
  /// in which case there might be some constant variables that lack
  /// initializers.
  Expression get constantInitializer => null;

  @override
  DartObject get constantValue => evaluationResult?.value;

  @override
  String get displayName => name;

  /// Return the result of evaluating this variable's initializer as a
  /// compile-time constant expression, or `null` if this variable is not a
  /// 'const' variable, if it does not have an initializer, or if the
  /// compilation unit containing the variable has not been resolved.
  EvaluationResultImpl get evaluationResult => null;

  /// Set the result of evaluating this variable's initializer as a compile-time
  /// constant expression to the given [result].
  void set evaluationResult(EvaluationResultImpl result) {
    throw new StateError(
        "Invalid attempt to set a compile-time constant result");
  }

  @override
  bool get hasImplicitType {
    return hasModifier(Modifier.IMPLICIT_TYPE);
  }

  /// Set whether this variable element has an implicit type.
  void set hasImplicitType(bool hasImplicitType) {
    setModifier(Modifier.IMPLICIT_TYPE, hasImplicitType);
  }

  @override
  FunctionElement get initializer => _initializer;

  /// Set the function representing this variable's initializer to the given
  /// [function].
  void set initializer(FunctionElement function) {
    if (function != null) {
      (function as FunctionElementImpl).enclosingElement = this;
    }
    this._initializer = function;
  }

  @override
  bool get isConst {
    if (linkedNode != null) {
      return enclosingUnit.linkedContext.isConst(linkedNode);
    }
    return hasModifier(Modifier.CONST);
  }

  /// Set whether this variable is const.
  void set isConst(bool isConst) {
    setModifier(Modifier.CONST, isConst);
  }

  @override
  bool get isConstantEvaluated => true;

  @override
  bool get isFinal {
    if (linkedNode != null) {
      return enclosingUnit.linkedContext.isFinal(linkedNode);
    }
    return hasModifier(Modifier.FINAL);
  }

  /// Set whether this variable is final.
  void set isFinal(bool isFinal) {
    setModifier(Modifier.FINAL, isFinal);
  }

  @override
  bool get isStatic => hasModifier(Modifier.STATIC);

  @override
  DartType get type => _type;

  void set type(DartType type) {
    if (linkedNode != null) {
      return linkedContext.setVariableType(linkedNode, type);
    }
    _type = _checkElementOfType(type);
  }

  /// Return the error reported during type inference for this variable, or
  /// `null` if this variable is not a subject of type inference, or there was
  /// no error.
  TopLevelInferenceError get typeInferenceError {
    return null;
  }

  @override
  void appendTo(StringBuffer buffer) {
    buffer.write(type);
    buffer.write(" ");
    buffer.write(displayName);
  }

  @override
  DartObject computeConstantValue() => null;

  @override
  void visitChildren(ElementVisitor visitor) {
    super.visitChildren(visitor);
    _initializer?.accept(visitor);
  }
}
