// Copyright (c) 2014, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/src/dart/element/element.dart';
import 'package:analyzer/src/dart/element/type.dart';
import 'package:analyzer/src/generated/engine.dart' show AnalysisContext;
import 'package:analyzer/src/generated/resolver.dart';
import 'package:analyzer/src/generated/testing/ast_test_factory.dart';
import 'package:analyzer/src/generated/testing/element_factory.dart';
import 'package:analyzer/src/generated/testing/test_type_provider.dart';
import 'package:test/test.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

import '../../../generated/elements_types_mixin.dart';
import '../../../generated/test_analysis_context.dart';
import '../resolution/driver_resolution.dart';

main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(ElementAnnotationImplTest);
    defineReflectiveTests(FieldElementImplTest);
    defineReflectiveTests(FunctionTypeImplTest);
    defineReflectiveTests(InterfaceTypeImplTest);
    defineReflectiveTests(TypeParameterTypeImplTest);
    defineReflectiveTests(VoidTypeImplTest);
    defineReflectiveTests(ClassElementImplTest);
    defineReflectiveTests(CompilationUnitElementImplTest);
    defineReflectiveTests(ElementLocationImplTest);
    defineReflectiveTests(ElementImplTest);
    defineReflectiveTests(LibraryElementImplTest);
    defineReflectiveTests(TopLevelVariableElementImplTest);
  });
}

class AbstractTypeTest with ElementsTypesMixin {
  AnalysisContext _analysisContext;
  TypeProvider _typeProvider;

  TypeProvider get typeProvider => _typeProvider;

  void setUp() {
    _analysisContext = TestAnalysisContext();
    _typeProvider = _analysisContext.typeProvider;
  }
}

@reflectiveTest
class ClassElementImplTest extends AbstractTypeTest {
  void test_getAllSupertypes_interface() {
    ClassElement classA = class_(name: 'A');
    ClassElement classB =
        ElementFactory.classElement("B", interfaceType(classA));
    ClassElementImpl elementC = ElementFactory.classElement2("C");
    InterfaceType typeObject = classA.supertype;
    InterfaceType typeA = interfaceType(classA);
    InterfaceType typeB = interfaceType(classB);
    InterfaceType typeC = interfaceType(elementC);
    elementC.interfaces = <InterfaceType>[typeB];
    List<InterfaceType> supers = elementC.allSupertypes;
    List<InterfaceType> types = new List<InterfaceType>();
    types.addAll(supers);
    expect(types.contains(typeA), isTrue);
    expect(types.contains(typeB), isTrue);
    expect(types.contains(typeObject), isTrue);
    expect(types.contains(typeC), isFalse);
  }

  void test_getAllSupertypes_mixins() {
    ClassElement classA = class_(name: 'A');
    ClassElement classB =
        ElementFactory.classElement("B", interfaceType(classA));
    var classC = ElementFactory.classElement2("C");
    InterfaceType typeObject = classA.supertype;
    InterfaceType typeA = interfaceType(classA);
    InterfaceType typeB = interfaceType(classB);
    InterfaceType typeC = interfaceType(classC);
    classC.mixins = <InterfaceType>[typeB];
    List<InterfaceType> supers = classC.allSupertypes;
    List<InterfaceType> types = new List<InterfaceType>();
    types.addAll(supers);
    expect(types.contains(typeA), isTrue);
    expect(types.contains(typeB), isTrue);
    expect(types.contains(typeObject), isTrue);
    expect(types.contains(typeC), isFalse);
  }

  void test_getAllSupertypes_recursive() {
    var classA = class_(name: 'A');
    ClassElementImpl classB =
        ElementFactory.classElement("B", interfaceType(classA));
    classA.supertype = interfaceType(classB);
    List<InterfaceType> supers = classB.allSupertypes;
    expect(supers, hasLength(1));
  }

  void test_getField() {
    var classA = class_(name: 'A');
    String fieldName = "f";
    FieldElementImpl field =
        ElementFactory.fieldElement(fieldName, false, false, false, null);
    classA.fields = <FieldElement>[field];
    expect(classA.getField(fieldName), same(field));
    expect(field.isEnumConstant, false);
    // no such field
    expect(classA.getField("noSuchField"), same(null));
  }

  void test_getMethod_declared() {
    var classA = class_(name: 'A');
    String methodName = "m";
    MethodElement method = ElementFactory.methodElement(methodName, null);
    classA.methods = <MethodElement>[method];
    expect(classA.getMethod(methodName), same(method));
  }

  void test_getMethod_undeclared() {
    var classA = class_(name: 'A');
    String methodName = "m";
    MethodElement method = ElementFactory.methodElement(methodName, null);
    classA.methods = <MethodElement>[method];
    expect(classA.getMethod("${methodName}x"), isNull);
  }

  void test_hasNonFinalField_false_const() {
    var classA = class_(name: 'A');
    classA.fields = <FieldElement>[
      ElementFactory.fieldElement(
          "f", false, false, true, interfaceType(classA))
    ];
    expect(classA.hasNonFinalField, isFalse);
  }

  void test_hasNonFinalField_false_final() {
    var classA = class_(name: 'A');
    classA.fields = <FieldElement>[
      ElementFactory.fieldElement(
          "f", false, true, false, interfaceType(classA))
    ];
    expect(classA.hasNonFinalField, isFalse);
  }

  void test_hasNonFinalField_false_recursive() {
    var classA = class_(name: 'A');
    ClassElementImpl classB =
        ElementFactory.classElement("B", interfaceType(classA));
    classA.supertype = interfaceType(classB);
    expect(classA.hasNonFinalField, isFalse);
  }

  void test_hasNonFinalField_true_immediate() {
    var classA = class_(name: 'A');
    classA.fields = <FieldElement>[
      ElementFactory.fieldElement(
          "f", false, false, false, interfaceType(classA))
    ];
    expect(classA.hasNonFinalField, isTrue);
  }

  void test_hasNonFinalField_true_inherited() {
    var classA = class_(name: 'A');
    ClassElementImpl classB =
        ElementFactory.classElement("B", interfaceType(classA));
    classA.fields = <FieldElement>[
      ElementFactory.fieldElement(
          "f", false, false, false, interfaceType(classA))
    ];
    expect(classB.hasNonFinalField, isTrue);
  }

  void test_hasStaticMember_false_empty() {
    var classA = class_(name: 'A');
    // no members
    expect(classA.hasStaticMember, isFalse);
  }

  void test_hasStaticMember_false_instanceMethod() {
    var classA = class_(name: 'A');
    MethodElement method = ElementFactory.methodElement("foo", null);
    classA.methods = <MethodElement>[method];
    expect(classA.hasStaticMember, isFalse);
  }

  void test_hasStaticMember_instanceGetter() {
    var classA = class_(name: 'A');
    PropertyAccessorElement getter =
        ElementFactory.getterElement("foo", false, null);
    classA.accessors = <PropertyAccessorElement>[getter];
    expect(classA.hasStaticMember, isFalse);
  }

  void test_hasStaticMember_true_getter() {
    var classA = class_(name: 'A');
    PropertyAccessorElementImpl getter =
        ElementFactory.getterElement("foo", false, null);
    classA.accessors = <PropertyAccessorElement>[getter];
    // "foo" is static
    getter.isStatic = true;
    expect(classA.hasStaticMember, isTrue);
  }

  void test_hasStaticMember_true_method() {
    var classA = class_(name: 'A');
    MethodElementImpl method = ElementFactory.methodElement("foo", null);
    classA.methods = <MethodElement>[method];
    // "foo" is static
    method.isStatic = true;
    expect(classA.hasStaticMember, isTrue);
  }

  void test_hasStaticMember_true_setter() {
    var classA = class_(name: 'A');
    PropertyAccessorElementImpl setter =
        ElementFactory.setterElement("foo", false, null);
    classA.accessors = <PropertyAccessorElement>[setter];
    // "foo" is static
    setter.isStatic = true;
    expect(classA.hasStaticMember, isTrue);
  }

  void test_isEnum() {
    String firstConst = "A";
    String secondConst = "B";
    EnumElementImpl enumE = ElementFactory.enumElement(
        new TestTypeProvider(), "E", [firstConst, secondConst]);

    // E is an enum
    expect(enumE.isEnum, true);

    // A and B are static members
    expect(enumE.getField(firstConst).isEnumConstant, true);
    expect(enumE.getField(secondConst).isEnumConstant, true);
  }

  void test_lookUpConcreteMethod_declared() {
    // class A {
    //   m() {}
    // }
    LibraryElementImpl library = _newLibrary();
    var classA = class_(name: 'A');
    String methodName = "m";
    MethodElement method = ElementFactory.methodElement(methodName, null);
    classA.methods = <MethodElement>[method];
    (library.definingCompilationUnit as CompilationUnitElementImpl).types =
        <ClassElement>[classA];
    expect(classA.lookUpConcreteMethod(methodName, library), same(method));
  }

  void test_lookUpConcreteMethod_declaredAbstract() {
    // class A {
    //   m();
    // }
    LibraryElementImpl library = _newLibrary();
    var classA = class_(name: 'A');
    String methodName = "m";
    MethodElementImpl method = ElementFactory.methodElement(methodName, null);
    method.isAbstract = true;
    classA.methods = <MethodElement>[method];
    (library.definingCompilationUnit as CompilationUnitElementImpl).types =
        <ClassElement>[classA];
    expect(classA.lookUpConcreteMethod(methodName, library), isNull);
  }

  void test_lookUpConcreteMethod_declaredAbstractAndInherited() {
    // class A {
    //   m() {}
    // }
    // class B extends A {
    //   m();
    // }
    LibraryElementImpl library = _newLibrary();
    var classA = class_(name: 'A');
    String methodName = "m";
    MethodElement inheritedMethod =
        ElementFactory.methodElement(methodName, null);
    classA.methods = <MethodElement>[inheritedMethod];
    ClassElementImpl classB =
        ElementFactory.classElement("B", interfaceType(classA));
    MethodElementImpl method = ElementFactory.methodElement(methodName, null);
    method.isAbstract = true;
    classB.methods = <MethodElement>[method];
    (library.definingCompilationUnit as CompilationUnitElementImpl).types =
        <ClassElement>[classA, classB];
    expect(classB.lookUpConcreteMethod(methodName, library),
        same(inheritedMethod));
  }

  void test_lookUpConcreteMethod_declaredAndInherited() {
    // class A {
    //   m() {}
    // }
    // class B extends A {
    //   m() {}
    // }
    LibraryElementImpl library = _newLibrary();
    var classA = class_(name: 'A');
    String methodName = "m";
    MethodElement inheritedMethod =
        ElementFactory.methodElement(methodName, null);
    classA.methods = <MethodElement>[inheritedMethod];
    ClassElementImpl classB =
        ElementFactory.classElement("B", interfaceType(classA));
    MethodElement method = ElementFactory.methodElement(methodName, null);
    classB.methods = <MethodElement>[method];
    (library.definingCompilationUnit as CompilationUnitElementImpl).types =
        <ClassElement>[classA, classB];
    expect(classB.lookUpConcreteMethod(methodName, library), same(method));
  }

  void test_lookUpConcreteMethod_declaredAndInheritedAbstract() {
    // abstract class A {
    //   m();
    // }
    // class B extends A {
    //   m() {}
    // }
    LibraryElementImpl library = _newLibrary();
    var classA = class_(name: 'A');
    classA.isAbstract = true;
    String methodName = "m";
    MethodElementImpl inheritedMethod =
        ElementFactory.methodElement(methodName, null);
    inheritedMethod.isAbstract = true;
    classA.methods = <MethodElement>[inheritedMethod];
    ClassElementImpl classB =
        ElementFactory.classElement("B", interfaceType(classA));
    MethodElement method = ElementFactory.methodElement(methodName, null);
    classB.methods = <MethodElement>[method];
    (library.definingCompilationUnit as CompilationUnitElementImpl).types =
        <ClassElement>[classA, classB];
    expect(classB.lookUpConcreteMethod(methodName, library), same(method));
  }

  void test_lookUpConcreteMethod_inherited() {
    // class A {
    //   m() {}
    // }
    // class B extends A {
    // }
    LibraryElementImpl library = _newLibrary();
    var classA = class_(name: 'A');
    String methodName = "m";
    MethodElement inheritedMethod =
        ElementFactory.methodElement(methodName, null);
    classA.methods = <MethodElement>[inheritedMethod];
    ClassElementImpl classB =
        ElementFactory.classElement("B", interfaceType(classA));
    (library.definingCompilationUnit as CompilationUnitElementImpl).types =
        <ClassElement>[classA, classB];
    expect(classB.lookUpConcreteMethod(methodName, library),
        same(inheritedMethod));
  }

  void test_lookUpConcreteMethod_undeclared() {
    // class A {
    // }
    LibraryElementImpl library = _newLibrary();
    var classA = class_(name: 'A');
    (library.definingCompilationUnit as CompilationUnitElementImpl).types =
        <ClassElement>[classA];
    expect(classA.lookUpConcreteMethod("m", library), isNull);
  }

  void test_lookUpGetter_declared() {
    // class A {
    //   get g {}
    // }
    LibraryElementImpl library = _newLibrary();
    var classA = class_(name: 'A');
    String getterName = "g";
    PropertyAccessorElement getter =
        ElementFactory.getterElement(getterName, false, null);
    classA.accessors = <PropertyAccessorElement>[getter];
    (library.definingCompilationUnit as CompilationUnitElementImpl).types =
        <ClassElement>[classA];
    expect(classA.lookUpGetter(getterName, library), same(getter));
  }

  void test_lookUpGetter_inherited() {
    // class A {
    //   get g {}
    // }
    // class B extends A {
    // }
    LibraryElementImpl library = _newLibrary();
    var classA = class_(name: 'A');
    String getterName = "g";
    PropertyAccessorElement getter =
        ElementFactory.getterElement(getterName, false, null);
    classA.accessors = <PropertyAccessorElement>[getter];
    ClassElementImpl classB =
        ElementFactory.classElement("B", interfaceType(classA));
    (library.definingCompilationUnit as CompilationUnitElementImpl).types =
        <ClassElement>[classA, classB];
    expect(classB.lookUpGetter(getterName, library), same(getter));
  }

  void test_lookUpGetter_undeclared() {
    // class A {
    // }
    LibraryElementImpl library = _newLibrary();
    var classA = class_(name: 'A');
    (library.definingCompilationUnit as CompilationUnitElementImpl).types =
        <ClassElement>[classA];
    expect(classA.lookUpGetter("g", library), isNull);
  }

  void test_lookUpGetter_undeclared_recursive() {
    // class A extends B {
    // }
    // class B extends A {
    // }
    LibraryElementImpl library = _newLibrary();
    var classA = class_(name: 'A');
    ClassElementImpl classB =
        ElementFactory.classElement("B", interfaceType(classA));
    classA.supertype = interfaceType(classB);
    (library.definingCompilationUnit as CompilationUnitElementImpl).types =
        <ClassElement>[classA, classB];
    expect(classA.lookUpGetter("g", library), isNull);
  }

  void test_lookUpInheritedConcreteGetter_declared() {
    // class A {
    //   get g {}
    // }
    LibraryElementImpl library = _newLibrary();
    var classA = class_(name: 'A');
    String getterName = "g";
    PropertyAccessorElement getter =
        ElementFactory.getterElement(getterName, false, null);
    classA.accessors = <PropertyAccessorElement>[getter];
    (library.definingCompilationUnit as CompilationUnitElementImpl).types =
        <ClassElement>[classA];
    expect(classA.lookUpInheritedConcreteGetter(getterName, library), isNull);
  }

  void test_lookUpInheritedConcreteGetter_inherited() {
    // class A {
    //   get g {}
    // }
    // class B extends A {
    // }
    LibraryElementImpl library = _newLibrary();
    var classA = class_(name: 'A');
    String getterName = "g";
    PropertyAccessorElement inheritedGetter =
        ElementFactory.getterElement(getterName, false, null);
    classA.accessors = <PropertyAccessorElement>[inheritedGetter];
    ClassElementImpl classB =
        ElementFactory.classElement("B", interfaceType(classA));
    (library.definingCompilationUnit as CompilationUnitElementImpl).types =
        <ClassElement>[classA, classB];
    expect(classB.lookUpInheritedConcreteGetter(getterName, library),
        same(inheritedGetter));
  }

  void test_lookUpInheritedConcreteGetter_undeclared() {
    // class A {
    // }
    LibraryElementImpl library = _newLibrary();
    var classA = class_(name: 'A');
    (library.definingCompilationUnit as CompilationUnitElementImpl).types =
        <ClassElement>[classA];
    expect(classA.lookUpInheritedConcreteGetter("g", library), isNull);
  }

  void test_lookUpInheritedConcreteGetter_undeclared_recursive() {
    // class A extends B {
    // }
    // class B extends A {
    // }
    LibraryElementImpl library = _newLibrary();
    var classA = class_(name: 'A');
    ClassElementImpl classB =
        ElementFactory.classElement("B", interfaceType(classA));
    classA.supertype = interfaceType(classB);
    (library.definingCompilationUnit as CompilationUnitElementImpl).types =
        <ClassElement>[classA, classB];
    expect(classA.lookUpInheritedConcreteGetter("g", library), isNull);
  }

  void test_lookUpInheritedConcreteMethod_declared() {
    // class A {
    //   m() {}
    // }
    LibraryElementImpl library = _newLibrary();
    var classA = class_(name: 'A');
    String methodName = "m";
    MethodElement method = ElementFactory.methodElement(methodName, null);
    classA.methods = <MethodElement>[method];
    (library.definingCompilationUnit as CompilationUnitElementImpl).types =
        <ClassElement>[classA];
    expect(classA.lookUpInheritedConcreteMethod(methodName, library), isNull);
  }

  void test_lookUpInheritedConcreteMethod_declaredAbstractAndInherited() {
    // class A {
    //   m() {}
    // }
    // class B extends A {
    //   m();
    // }
    LibraryElementImpl library = _newLibrary();
    var classA = class_(name: 'A');
    String methodName = "m";
    MethodElement inheritedMethod =
        ElementFactory.methodElement(methodName, null);
    classA.methods = <MethodElement>[inheritedMethod];
    ClassElementImpl classB =
        ElementFactory.classElement("B", interfaceType(classA));
    MethodElementImpl method = ElementFactory.methodElement(methodName, null);
    method.isAbstract = true;
    classB.methods = <MethodElement>[method];
    (library.definingCompilationUnit as CompilationUnitElementImpl).types =
        <ClassElement>[classA, classB];
    expect(classB.lookUpInheritedConcreteMethod(methodName, library),
        same(inheritedMethod));
  }

  void test_lookUpInheritedConcreteMethod_declaredAndInherited() {
    // class A {
    //   m() {}
    // }
    // class B extends A {
    //   m() {}
    // }
    LibraryElementImpl library = _newLibrary();
    var classA = class_(name: 'A');
    String methodName = "m";
    MethodElement inheritedMethod =
        ElementFactory.methodElement(methodName, null);
    classA.methods = <MethodElement>[inheritedMethod];
    ClassElementImpl classB =
        ElementFactory.classElement("B", interfaceType(classA));
    MethodElement method = ElementFactory.methodElement(methodName, null);
    classB.methods = <MethodElement>[method];
    (library.definingCompilationUnit as CompilationUnitElementImpl).types =
        <ClassElement>[classA, classB];
    expect(classB.lookUpInheritedConcreteMethod(methodName, library),
        same(inheritedMethod));
  }

  void test_lookUpInheritedConcreteMethod_declaredAndInheritedAbstract() {
    // abstract class A {
    //   m();
    // }
    // class B extends A {
    //   m() {}
    // }
    LibraryElementImpl library = _newLibrary();
    var classA = class_(name: 'A');
    classA.isAbstract = true;
    String methodName = "m";
    MethodElementImpl inheritedMethod =
        ElementFactory.methodElement(methodName, null);
    inheritedMethod.isAbstract = true;
    classA.methods = <MethodElement>[inheritedMethod];
    ClassElementImpl classB =
        ElementFactory.classElement("B", interfaceType(classA));
    MethodElement method = ElementFactory.methodElement(methodName, null);
    classB.methods = <MethodElement>[method];
    (library.definingCompilationUnit as CompilationUnitElementImpl).types =
        <ClassElement>[classA, classB];
    expect(classB.lookUpInheritedConcreteMethod(methodName, library), isNull);
  }

  void
      test_lookUpInheritedConcreteMethod_declaredAndInheritedWithAbstractBetween() {
    // class A {
    //   m() {}
    // }
    // class B extends A {
    //   m();
    // }
    // class C extends B {
    //   m() {}
    // }
    LibraryElementImpl library = _newLibrary();
    var classA = class_(name: 'A');
    String methodName = "m";
    MethodElement inheritedMethod =
        ElementFactory.methodElement(methodName, null);
    classA.methods = <MethodElement>[inheritedMethod];
    ClassElementImpl classB =
        ElementFactory.classElement("B", interfaceType(classA));
    MethodElementImpl abstractMethod =
        ElementFactory.methodElement(methodName, null);
    abstractMethod.isAbstract = true;
    classB.methods = <MethodElement>[abstractMethod];
    ClassElementImpl classC =
        ElementFactory.classElement("C", interfaceType(classB));
    MethodElementImpl method = ElementFactory.methodElement(methodName, null);
    classC.methods = <MethodElement>[method];
    (library.definingCompilationUnit as CompilationUnitElementImpl).types =
        <ClassElement>[classA, classB, classC];
    expect(classC.lookUpInheritedConcreteMethod(methodName, library),
        same(inheritedMethod));
  }

  void test_lookUpInheritedConcreteMethod_inherited() {
    // class A {
    //   m() {}
    // }
    // class B extends A {
    // }
    LibraryElementImpl library = _newLibrary();
    var classA = class_(name: 'A');
    String methodName = "m";
    MethodElement inheritedMethod =
        ElementFactory.methodElement(methodName, null);
    classA.methods = <MethodElement>[inheritedMethod];
    ClassElementImpl classB =
        ElementFactory.classElement("B", interfaceType(classA));
    (library.definingCompilationUnit as CompilationUnitElementImpl).types =
        <ClassElement>[classA, classB];
    expect(classB.lookUpInheritedConcreteMethod(methodName, library),
        same(inheritedMethod));
  }

  void test_lookUpInheritedConcreteMethod_undeclared() {
    // class A {
    // }
    LibraryElementImpl library = _newLibrary();
    var classA = class_(name: 'A');
    (library.definingCompilationUnit as CompilationUnitElementImpl).types =
        <ClassElement>[classA];
    expect(classA.lookUpInheritedConcreteMethod("m", library), isNull);
  }

  void test_lookUpInheritedConcreteSetter_declared() {
    // class A {
    //   set g(x) {}
    // }
    LibraryElementImpl library = _newLibrary();
    var classA = class_(name: 'A');
    String setterName = "s";
    PropertyAccessorElement setter =
        ElementFactory.setterElement(setterName, false, null);
    classA.accessors = <PropertyAccessorElement>[setter];
    (library.definingCompilationUnit as CompilationUnitElementImpl).types =
        <ClassElement>[classA];
    expect(classA.lookUpInheritedConcreteSetter(setterName, library), isNull);
  }

  void test_lookUpInheritedConcreteSetter_inherited() {
    // class A {
    //   set g(x) {}
    // }
    // class B extends A {
    // }
    LibraryElementImpl library = _newLibrary();
    var classA = class_(name: 'A');
    String setterName = "s";
    PropertyAccessorElement setter =
        ElementFactory.setterElement(setterName, false, null);
    classA.accessors = <PropertyAccessorElement>[setter];
    ClassElementImpl classB =
        ElementFactory.classElement("B", interfaceType(classA));
    (library.definingCompilationUnit as CompilationUnitElementImpl).types =
        <ClassElement>[classA, classB];
    expect(classB.lookUpInheritedConcreteSetter(setterName, library),
        same(setter));
  }

  void test_lookUpInheritedConcreteSetter_undeclared() {
    // class A {
    // }
    LibraryElementImpl library = _newLibrary();
    var classA = class_(name: 'A');
    (library.definingCompilationUnit as CompilationUnitElementImpl).types =
        <ClassElement>[classA];
    expect(classA.lookUpInheritedConcreteSetter("s", library), isNull);
  }

  void test_lookUpInheritedConcreteSetter_undeclared_recursive() {
    // class A extends B {
    // }
    // class B extends A {
    // }
    LibraryElementImpl library = _newLibrary();
    var classA = class_(name: 'A');
    ClassElementImpl classB =
        ElementFactory.classElement("B", interfaceType(classA));
    classA.supertype = interfaceType(classB);
    (library.definingCompilationUnit as CompilationUnitElementImpl).types =
        <ClassElement>[classA, classB];
    expect(classA.lookUpInheritedConcreteSetter("s", library), isNull);
  }

  void test_lookUpInheritedMethod_declared() {
    // class A {
    //   m() {}
    // }
    LibraryElementImpl library = _newLibrary();
    var classA = class_(name: 'A');
    String methodName = "m";
    MethodElement method = ElementFactory.methodElement(methodName, null);
    classA.methods = <MethodElement>[method];
    (library.definingCompilationUnit as CompilationUnitElementImpl).types =
        <ClassElement>[classA];
    expect(classA.lookUpInheritedMethod(methodName, library), isNull);
  }

  void test_lookUpInheritedMethod_declaredAndInherited() {
    // class A {
    //   m() {}
    // }
    // class B extends A {
    //   m() {}
    // }
    LibraryElementImpl library = _newLibrary();
    var classA = class_(name: 'A');
    String methodName = "m";
    MethodElement inheritedMethod =
        ElementFactory.methodElement(methodName, null);
    classA.methods = <MethodElement>[inheritedMethod];
    ClassElementImpl classB =
        ElementFactory.classElement("B", interfaceType(classA));
    MethodElement method = ElementFactory.methodElement(methodName, null);
    classB.methods = <MethodElement>[method];
    (library.definingCompilationUnit as CompilationUnitElementImpl).types =
        <ClassElement>[classA, classB];
    expect(classB.lookUpInheritedMethod(methodName, library),
        same(inheritedMethod));
  }

  void test_lookUpInheritedMethod_inherited() {
    // class A {
    //   m() {}
    // }
    // class B extends A {
    // }
    LibraryElementImpl library = _newLibrary();
    var classA = class_(name: 'A');
    String methodName = "m";
    MethodElement inheritedMethod =
        ElementFactory.methodElement(methodName, null);
    classA.methods = <MethodElement>[inheritedMethod];
    ClassElementImpl classB =
        ElementFactory.classElement("B", interfaceType(classA));
    (library.definingCompilationUnit as CompilationUnitElementImpl).types =
        <ClassElement>[classA, classB];
    expect(classB.lookUpInheritedMethod(methodName, library),
        same(inheritedMethod));
  }

  void test_lookUpInheritedMethod_undeclared() {
    // class A {
    // }
    LibraryElementImpl library = _newLibrary();
    var classA = class_(name: 'A');
    (library.definingCompilationUnit as CompilationUnitElementImpl).types =
        <ClassElement>[classA];
    expect(classA.lookUpInheritedMethod("m", library), isNull);
  }

  void test_lookUpMethod_declared() {
    LibraryElementImpl library = _newLibrary();
    var classA = class_(name: 'A');
    String methodName = "m";
    MethodElement method = ElementFactory.methodElement(methodName, null);
    classA.methods = <MethodElement>[method];
    (library.definingCompilationUnit as CompilationUnitElementImpl).types =
        <ClassElement>[classA];
    expect(classA.lookUpMethod(methodName, library), same(method));
  }

  void test_lookUpMethod_inherited() {
    LibraryElementImpl library = _newLibrary();
    var classA = class_(name: 'A');
    String methodName = "m";
    MethodElement method = ElementFactory.methodElement(methodName, null);
    classA.methods = <MethodElement>[method];
    ClassElementImpl classB =
        ElementFactory.classElement("B", interfaceType(classA));
    (library.definingCompilationUnit as CompilationUnitElementImpl).types =
        <ClassElement>[classA, classB];
    expect(classB.lookUpMethod(methodName, library), same(method));
  }

  void test_lookUpMethod_undeclared() {
    LibraryElementImpl library = _newLibrary();
    var classA = class_(name: 'A');
    (library.definingCompilationUnit as CompilationUnitElementImpl).types =
        <ClassElement>[classA];
    expect(classA.lookUpMethod("m", library), isNull);
  }

  void test_lookUpMethod_undeclared_recursive() {
    LibraryElementImpl library = _newLibrary();
    var classA = class_(name: 'A');
    ClassElementImpl classB =
        ElementFactory.classElement("B", interfaceType(classA));
    classA.supertype = interfaceType(classB);
    (library.definingCompilationUnit as CompilationUnitElementImpl).types =
        <ClassElement>[classA, classB];
    expect(classA.lookUpMethod("m", library), isNull);
  }

  void test_lookUpSetter_declared() {
    // class A {
    //   set g(x) {}
    // }
    LibraryElementImpl library = _newLibrary();
    var classA = class_(name: 'A');
    String setterName = "s";
    PropertyAccessorElement setter =
        ElementFactory.setterElement(setterName, false, null);
    classA.accessors = <PropertyAccessorElement>[setter];
    (library.definingCompilationUnit as CompilationUnitElementImpl).types =
        <ClassElement>[classA];
    expect(classA.lookUpSetter(setterName, library), same(setter));
  }

  void test_lookUpSetter_inherited() {
    // class A {
    //   set g(x) {}
    // }
    // class B extends A {
    // }
    LibraryElementImpl library = _newLibrary();
    var classA = class_(name: 'A');
    String setterName = "s";
    PropertyAccessorElement setter =
        ElementFactory.setterElement(setterName, false, null);
    classA.accessors = <PropertyAccessorElement>[setter];
    ClassElementImpl classB =
        ElementFactory.classElement("B", interfaceType(classA));
    (library.definingCompilationUnit as CompilationUnitElementImpl).types =
        <ClassElement>[classA, classB];
    expect(classB.lookUpSetter(setterName, library), same(setter));
  }

  void test_lookUpSetter_undeclared() {
    // class A {
    // }
    LibraryElementImpl library = _newLibrary();
    var classA = class_(name: 'A');
    (library.definingCompilationUnit as CompilationUnitElementImpl).types =
        <ClassElement>[classA];
    expect(classA.lookUpSetter("s", library), isNull);
  }

  void test_lookUpSetter_undeclared_recursive() {
    // class A extends B {
    // }
    // class B extends A {
    // }
    LibraryElementImpl library = _newLibrary();
    var classA = class_(name: 'A');
    ClassElementImpl classB =
        ElementFactory.classElement("B", interfaceType(classA));
    classA.supertype = interfaceType(classB);
    (library.definingCompilationUnit as CompilationUnitElementImpl).types =
        <ClassElement>[classA, classB];
    expect(classA.lookUpSetter("s", library), isNull);
  }

  LibraryElementImpl _newLibrary() => ElementFactory.library(null, 'lib');
}

@reflectiveTest
class CompilationUnitElementImplTest {
  void test_getEnum_declared() {
    TestTypeProvider typeProvider = new TestTypeProvider();
    CompilationUnitElementImpl unit =
        ElementFactory.compilationUnit("/lib.dart");
    String enumName = "E";
    ClassElement enumElement =
        ElementFactory.enumElement(typeProvider, enumName);
    unit.enums = <ClassElement>[enumElement];
    expect(unit.getEnum(enumName), same(enumElement));
  }

  void test_getEnum_undeclared() {
    TestTypeProvider typeProvider = new TestTypeProvider();
    CompilationUnitElementImpl unit =
        ElementFactory.compilationUnit("/lib.dart");
    String enumName = "E";
    ClassElement enumElement =
        ElementFactory.enumElement(typeProvider, enumName);
    unit.enums = <ClassElement>[enumElement];
    expect(unit.getEnum("${enumName}x"), isNull);
  }

  void test_getType_declared() {
    CompilationUnitElementImpl unit =
        ElementFactory.compilationUnit("/lib.dart");
    String className = "C";
    ClassElement classElement = ElementFactory.classElement2(className);
    unit.types = <ClassElement>[classElement];
    expect(unit.getType(className), same(classElement));
  }

  void test_getType_undeclared() {
    CompilationUnitElementImpl unit =
        ElementFactory.compilationUnit("/lib.dart");
    String className = "C";
    ClassElement classElement = ElementFactory.classElement2(className);
    unit.types = <ClassElement>[classElement];
    expect(unit.getType("${className}x"), isNull);
  }
}

@reflectiveTest
class ElementAnnotationImplTest extends DriverResolutionTest {
  test_computeConstantValue() async {
    newFile('/test/lib/a.dart', content: r'''
class A {
  final String f;
  const A(this.f);
}
void f(@A('x') int p) {}
''');
    await resolveTestCode(r'''
import 'a.dart';
main() {
  f(3);
}
''');
    var argument = findNode.integerLiteral('3');
    ParameterElement parameter = argument.staticParameterElement;

    ElementAnnotation annotation = parameter.metadata[0];
    expect(annotation.constantValue, isNull);

    DartObject value = annotation.computeConstantValue();
    expect(value, isNotNull);
    expect(value.getField('f').toStringValue(), 'x');
    expect(annotation.constantValue, value);
  }
}

@reflectiveTest
class ElementImplTest extends AbstractTypeTest {
  void test_equals() {
    LibraryElementImpl library =
        ElementFactory.library(_analysisContext, "lib");
    ClassElementImpl classElement = ElementFactory.classElement2("C");
    (library.definingCompilationUnit as CompilationUnitElementImpl).types =
        <ClassElement>[classElement];
    FieldElement field = ElementFactory.fieldElement(
      "next",
      false,
      false,
      false,
      classElement.instantiate(
        typeArguments: [],
        nullabilitySuffix: NullabilitySuffix.star,
      ),
    );
    classElement.fields = <FieldElement>[field];
    expect(field == field, isTrue);
    // ignore: unrelated_type_equality_checks
    expect(field == field.getter, isFalse);
    // ignore: unrelated_type_equality_checks
    expect(field == field.setter, isFalse);
    expect(field.getter == field.setter, isFalse);
  }

  void test_isAccessibleIn_private_differentLibrary() {
    LibraryElementImpl library1 =
        ElementFactory.library(_analysisContext, "lib1");
    ClassElement classElement = ElementFactory.classElement2("_C");
    (library1.definingCompilationUnit as CompilationUnitElementImpl).types =
        <ClassElement>[classElement];
    LibraryElementImpl library2 =
        ElementFactory.library(_analysisContext, "lib2");
    expect(classElement.isAccessibleIn(library2), isFalse);
  }

  void test_isAccessibleIn_private_sameLibrary() {
    LibraryElementImpl library =
        ElementFactory.library(_analysisContext, "lib");
    ClassElement classElement = ElementFactory.classElement2("_C");
    (library.definingCompilationUnit as CompilationUnitElementImpl).types =
        <ClassElement>[classElement];
    expect(classElement.isAccessibleIn(library), isTrue);
  }

  void test_isAccessibleIn_public_differentLibrary() {
    LibraryElementImpl library1 =
        ElementFactory.library(_analysisContext, "lib1");
    ClassElement classElement = ElementFactory.classElement2("C");
    (library1.definingCompilationUnit as CompilationUnitElementImpl).types =
        <ClassElement>[classElement];
    LibraryElementImpl library2 =
        ElementFactory.library(_analysisContext, "lib2");
    expect(classElement.isAccessibleIn(library2), isTrue);
  }

  void test_isAccessibleIn_public_sameLibrary() {
    LibraryElementImpl library =
        ElementFactory.library(_analysisContext, "lib");
    ClassElement classElement = ElementFactory.classElement2("C");
    (library.definingCompilationUnit as CompilationUnitElementImpl).types =
        <ClassElement>[classElement];
    expect(classElement.isAccessibleIn(library), isTrue);
  }

  void test_isPrivate_false() {
    Element element = ElementFactory.classElement2("C");
    expect(element.isPrivate, isFalse);
  }

  void test_isPrivate_null() {
    Element element = ElementFactory.classElement2(null);
    expect(element.isPrivate, isTrue);
  }

  void test_isPrivate_true() {
    Element element = ElementFactory.classElement2("_C");
    expect(element.isPrivate, isTrue);
  }

  void test_isPublic_false() {
    Element element = ElementFactory.classElement2("_C");
    expect(element.isPublic, isFalse);
  }

  void test_isPublic_null() {
    Element element = ElementFactory.classElement2(null);
    expect(element.isPublic, isFalse);
  }

  void test_isPublic_true() {
    Element element = ElementFactory.classElement2("C");
    expect(element.isPublic, isTrue);
  }

  void test_SORT_BY_OFFSET() {
    ClassElementImpl classElementA = class_(name: 'A');
    classElementA.nameOffset = 1;
    ClassElementImpl classElementB = ElementFactory.classElement2("B");
    classElementB.nameOffset = 2;
    expect(Element.SORT_BY_OFFSET(classElementA, classElementA), 0);
    expect(Element.SORT_BY_OFFSET(classElementA, classElementB) < 0, isTrue);
    expect(Element.SORT_BY_OFFSET(classElementB, classElementA) > 0, isTrue);
  }
}

@reflectiveTest
class ElementLocationImplTest {
  void test_create_encoding() {
    String encoding = "a;b;c";
    ElementLocationImpl location = new ElementLocationImpl.con2(encoding);
    expect(location.encoding, encoding);
  }

  /**
   * For example unnamed constructor.
   */
  void test_create_encoding_emptyLast() {
    String encoding = "a;b;c;";
    ElementLocationImpl location = new ElementLocationImpl.con2(encoding);
    expect(location.encoding, encoding);
  }

  void test_equals_equal() {
    String encoding = "a;b;c";
    ElementLocationImpl first = new ElementLocationImpl.con2(encoding);
    ElementLocationImpl second = new ElementLocationImpl.con2(encoding);
    expect(first == second, isTrue);
  }

  void test_equals_notEqual_differentLengths() {
    ElementLocationImpl first = new ElementLocationImpl.con2("a;b;c");
    ElementLocationImpl second = new ElementLocationImpl.con2("a;b;c;d");
    expect(first == second, isFalse);
  }

  void test_equals_notEqual_notLocation() {
    ElementLocationImpl first = new ElementLocationImpl.con2("a;b;c");
    // ignore: unrelated_type_equality_checks
    expect(first == "a;b;d", isFalse);
  }

  void test_equals_notEqual_sameLengths() {
    ElementLocationImpl first = new ElementLocationImpl.con2("a;b;c");
    ElementLocationImpl second = new ElementLocationImpl.con2("a;b;d");
    expect(first == second, isFalse);
  }

  void test_getComponents() {
    String encoding = "a;b;c";
    ElementLocationImpl location = new ElementLocationImpl.con2(encoding);
    List<String> components = location.components;
    expect(components, hasLength(3));
    expect(components[0], "a");
    expect(components[1], "b");
    expect(components[2], "c");
  }

  void test_getEncoding() {
    String encoding = "a;b;c;;d";
    ElementLocationImpl location = new ElementLocationImpl.con2(encoding);
    expect(location.encoding, encoding);
  }

  void test_hashCode_equal() {
    String encoding = "a;b;c";
    ElementLocationImpl first = new ElementLocationImpl.con2(encoding);
    ElementLocationImpl second = new ElementLocationImpl.con2(encoding);
    expect(first.hashCode == second.hashCode, isTrue);
  }
}

@reflectiveTest
class FieldElementImplTest extends DriverResolutionTest {
  test_isEnumConstant() async {
    await resolveTestCode(r'''
enum B {B1, B2, B3}
''');
    var B = findElement.enum_('B');

    FieldElement b2Element = B.getField('B2');
    expect(b2Element.isEnumConstant, isTrue);

    FieldElement indexElement = B.getField('index');
    expect(indexElement.isEnumConstant, isFalse);
  }
}

@reflectiveTest
class FunctionTypeImplTest extends AbstractTypeTest {
  void test_equality_recursive() {
    var s = ElementFactory.genericTypeAliasElement('s');
    var t = ElementFactory.genericTypeAliasElement('t');
    var u = ElementFactory.genericTypeAliasElement('u');
    var v = ElementFactory.genericTypeAliasElement('v');
    s.function.returnType = functionTypeAliasType(t);
    t.function.returnType = functionTypeAliasType(s);
    u.function.returnType = functionTypeAliasType(v);
    v.function.returnType = functionTypeAliasType(u);
    // We don't care whether the types compare equal or not.  We just need the
    // computation to terminate.
    expect(
      functionTypeAliasType(s) == functionTypeAliasType(u),
      new TypeMatcher<bool>(),
    );
  }

  void test_getNamedParameterTypes_namedParameters() {
    TestTypeProvider typeProvider = new TestTypeProvider();
    FunctionElement element = ElementFactory.functionElementWithParameters(
        'f', VoidTypeImpl.instance, [
      ElementFactory.requiredParameter2('a', typeProvider.intType),
      ElementFactory.requiredParameter2('b', typeProvider.dynamicType),
      ElementFactory.namedParameter2('c', typeProvider.stringType),
      ElementFactory.namedParameter2('d', typeProvider.dynamicType)
    ]);
    FunctionTypeImpl type = element.type;
    Map<String, DartType> types = type.namedParameterTypes;
    expect(types, hasLength(2));
    expect(types['c'], typeProvider.stringType);
    expect(types['d'], DynamicTypeImpl.instance);
  }

  void test_getNamedParameterTypes_noNamedParameters() {
    TestTypeProvider typeProvider = new TestTypeProvider();
    FunctionElement element = ElementFactory.functionElementWithParameters(
        'f', VoidTypeImpl.instance, [
      ElementFactory.requiredParameter2('a', typeProvider.intType),
      ElementFactory.requiredParameter2('b', typeProvider.dynamicType),
      ElementFactory.positionalParameter2('c', typeProvider.stringType)
    ]);
    FunctionTypeImpl type = element.type;
    Map<String, DartType> types = type.namedParameterTypes;
    expect(types, hasLength(0));
  }

  void test_getNamedParameterTypes_noParameters() {
    FunctionTypeImpl type = ElementFactory.functionElement('f').type;
    Map<String, DartType> types = type.namedParameterTypes;
    expect(types, hasLength(0));
  }

  void test_getNormalParameterTypes_noNormalParameters() {
    TestTypeProvider typeProvider = new TestTypeProvider();
    FunctionElement element = ElementFactory.functionElementWithParameters(
        'f', VoidTypeImpl.instance, [
      ElementFactory.positionalParameter2('c', typeProvider.stringType),
      ElementFactory.positionalParameter2('d', typeProvider.dynamicType)
    ]);
    FunctionTypeImpl type = element.type;
    List<DartType> types = type.normalParameterTypes;
    expect(types, hasLength(0));
  }

  void test_getNormalParameterTypes_noParameters() {
    FunctionTypeImpl type = ElementFactory.functionElement('f').type;
    List<DartType> types = type.normalParameterTypes;
    expect(types, hasLength(0));
  }

  void test_getNormalParameterTypes_normalParameters() {
    TestTypeProvider typeProvider = new TestTypeProvider();
    FunctionElement element = ElementFactory.functionElementWithParameters(
        'f', VoidTypeImpl.instance, [
      ElementFactory.requiredParameter2('a', typeProvider.intType),
      ElementFactory.requiredParameter2('b', typeProvider.dynamicType),
      ElementFactory.positionalParameter2('c', typeProvider.stringType)
    ]);
    FunctionTypeImpl type = element.type;
    List<DartType> types = type.normalParameterTypes;
    expect(types, hasLength(2));
    expect(types[0], typeProvider.intType);
    expect(types[1], DynamicTypeImpl.instance);
  }

  void test_getOptionalParameterTypes_noOptionalParameters() {
    TestTypeProvider typeProvider = new TestTypeProvider();
    FunctionElement element = ElementFactory.functionElementWithParameters(
        'f', VoidTypeImpl.instance, [
      ElementFactory.requiredParameter2('a', typeProvider.intType),
      ElementFactory.requiredParameter2('b', typeProvider.dynamicType),
      ElementFactory.namedParameter2('c', typeProvider.stringType),
      ElementFactory.namedParameter2('d', typeProvider.dynamicType)
    ]);
    FunctionTypeImpl type = element.type;
    List<DartType> types = type.optionalParameterTypes;
    expect(types, hasLength(0));
  }

  void test_getOptionalParameterTypes_noParameters() {
    FunctionTypeImpl type = ElementFactory.functionElement('f').type;
    List<DartType> types = type.optionalParameterTypes;
    expect(types, hasLength(0));
  }

  void test_getOptionalParameterTypes_optionalParameters() {
    TestTypeProvider typeProvider = new TestTypeProvider();
    FunctionElement element = ElementFactory.functionElementWithParameters(
        'f', VoidTypeImpl.instance, [
      ElementFactory.requiredParameter2('a', typeProvider.intType),
      ElementFactory.requiredParameter2('b', typeProvider.dynamicType),
      ElementFactory.positionalParameter2('c', typeProvider.stringType),
      ElementFactory.positionalParameter2('d', typeProvider.dynamicType)
    ]);
    FunctionTypeImpl type = element.type;
    List<DartType> types = type.optionalParameterTypes;
    expect(types, hasLength(2));
    expect(types[0], typeProvider.stringType);
    expect(types[1], DynamicTypeImpl.instance);
  }

  void test_resolveToBound() {
    FunctionElementImpl f = ElementFactory.functionElement('f');
    FunctionTypeImpl type = f.type;

    // Returns this.
    expect(type.resolveToBound(null), same(type));
  }

  @deprecated
  void test_substitute2_equal() {
    ClassElementImpl definingClass = ElementFactory.classElement2("C", ["E"]);
    TypeParameterType parameterType =
        typeParameterType(definingClass.typeParameters[0]);
    MethodElementImpl functionElement =
        new MethodElementImpl.forNode(AstTestFactory.identifier3("m"));
    String namedParameterName = "c";
    functionElement.parameters = <ParameterElement>[
      ElementFactory.requiredParameter2("a", parameterType),
      ElementFactory.positionalParameter2("b", parameterType),
      ElementFactory.namedParameter2(namedParameterName, parameterType)
    ];
    functionElement.returnType = parameterType;
    definingClass.methods = <MethodElement>[functionElement];
    FunctionTypeImpl functionType = functionElement.type;
    InterfaceTypeImpl argumentType = new InterfaceTypeImpl(
        new ClassElementImpl.forNode(AstTestFactory.identifier3("D")));
    FunctionType result = functionType
        .substitute2(<DartType>[argumentType], <DartType>[parameterType]);
    expect(result.returnType, argumentType);
    List<DartType> normalParameters = result.normalParameterTypes;
    expect(normalParameters, hasLength(1));
    expect(normalParameters[0], argumentType);
    List<DartType> optionalParameters = result.optionalParameterTypes;
    expect(optionalParameters, hasLength(1));
    expect(optionalParameters[0], argumentType);
    Map<String, DartType> namedParameters = result.namedParameterTypes;
    expect(namedParameters, hasLength(1));
    expect(namedParameters[namedParameterName], argumentType);
  }

  @deprecated
  void test_substitute2_notEqual() {
    DartType returnType = new InterfaceTypeImpl(
        new ClassElementImpl.forNode(AstTestFactory.identifier3("R")));
    DartType normalParameterType = new InterfaceTypeImpl(
        new ClassElementImpl.forNode(AstTestFactory.identifier3("A")));
    DartType optionalParameterType = new InterfaceTypeImpl(
        new ClassElementImpl.forNode(AstTestFactory.identifier3("B")));
    DartType namedParameterType = new InterfaceTypeImpl(
        new ClassElementImpl.forNode(AstTestFactory.identifier3("C")));
    FunctionElementImpl functionElement =
        new FunctionElementImpl.forNode(AstTestFactory.identifier3("f"));
    String namedParameterName = "c";
    functionElement.parameters = <ParameterElement>[
      ElementFactory.requiredParameter2("a", normalParameterType),
      ElementFactory.positionalParameter2("b", optionalParameterType),
      ElementFactory.namedParameter2(namedParameterName, namedParameterType)
    ];
    functionElement.returnType = returnType;
    FunctionTypeImpl functionType = functionElement.type;
    InterfaceTypeImpl argumentType = new InterfaceTypeImpl(
        new ClassElementImpl.forNode(AstTestFactory.identifier3("D")));
    TypeParameterTypeImpl parameterType = new TypeParameterTypeImpl(
        new TypeParameterElementImpl.forNode(AstTestFactory.identifier3("E")));
    FunctionType result = functionType
        .substitute2(<DartType>[argumentType], <DartType>[parameterType]);
    expect(result.returnType, returnType);
    List<DartType> normalParameters = result.normalParameterTypes;
    expect(normalParameters, hasLength(1));
    expect(normalParameters[0], normalParameterType);
    List<DartType> optionalParameters = result.optionalParameterTypes;
    expect(optionalParameters, hasLength(1));
    expect(optionalParameters[0], optionalParameterType);
    Map<String, DartType> namedParameters = result.namedParameterTypes;
    expect(namedParameters, hasLength(1));
    expect(namedParameters[namedParameterName], namedParameterType);
  }

  void test_toString_recursive() {
    var t = ElementFactory.genericTypeAliasElement("t");
    var s = ElementFactory.genericTypeAliasElement("s");
    t.function.returnType = functionTypeAliasType(s);
    s.function.returnType = functionTypeAliasType(t);
    expect(
      functionTypeAliasType(t).toString(),
      'dynamic Function() Function()',
    );
  }

  void test_toString_recursive_via_interface_type() {
    var f = ElementFactory.genericTypeAliasElement('f');
    ClassElementImpl c = ElementFactory.classElement2('C', ['T']);
    f.function.returnType = c.instantiate(
      typeArguments: [functionTypeAliasType(f)],
      nullabilitySuffix: NullabilitySuffix.star,
    );
    expect(
      functionTypeAliasType(f).toString(),
      'dynamic Function()',
    );
  }
}

@reflectiveTest
class InterfaceTypeImplTest extends AbstractTypeTest {
  test_asInstanceOf_explicitGeneric() {
    // class A<E> {}
    // class B implements A<C> {}
    // class C {}
    var A = class_(name: 'A', typeParameters: [
      typeParameter('E'),
    ]);
    var B = class_(name: 'B');
    var C = class_(name: 'C');

    var AofC = A.instantiate(
      typeArguments: [
        interfaceType(C),
      ],
      nullabilitySuffix: NullabilitySuffix.star,
    );

    B.interfaces = <InterfaceType>[AofC];

    InterfaceTypeImpl targetType = interfaceType(B);
    InterfaceType result = targetType.asInstanceOf(A);
    expect(result, AofC);
  }

  test_asInstanceOf_passThroughGeneric() {
    // class A<E> {}
    // class B<E> implements A<E> {}
    // class C {}
    var AE = typeParameter('E');
    var A = class_(name: 'A', typeParameters: [AE]);

    var BE = typeParameter('E');
    var B = class_(
      name: 'B',
      typeParameters: [BE],
      interfaces: [
        A.instantiate(
          typeArguments: [typeParameterType(BE)],
          nullabilitySuffix: NullabilitySuffix.star,
        ),
      ],
    );

    var C = class_(name: 'C');

    InterfaceTypeImpl targetType = B.instantiate(
      typeArguments: [interfaceType(C)],
      nullabilitySuffix: NullabilitySuffix.star,
    );
    InterfaceType result = targetType.asInstanceOf(A);
    expect(
      result,
      A.instantiate(
        typeArguments: [interfaceType(C)],
        nullabilitySuffix: NullabilitySuffix.star,
      ),
    );
  }

  void test_creation() {
    expect(new InterfaceTypeImpl(class_(name: 'A')), isNotNull);
  }

  void test_getAccessors() {
    ClassElementImpl typeElement = class_(name: 'A');
    PropertyAccessorElement getterG =
        ElementFactory.getterElement("g", false, null);
    PropertyAccessorElement getterH =
        ElementFactory.getterElement("h", false, null);
    typeElement.accessors = <PropertyAccessorElement>[getterG, getterH];
    InterfaceTypeImpl type = new InterfaceTypeImpl(typeElement);
    expect(type.accessors.length, 2);
  }

  void test_getAccessors_empty() {
    ClassElementImpl typeElement = class_(name: 'A');
    InterfaceTypeImpl type = new InterfaceTypeImpl(typeElement);
    expect(type.accessors.length, 0);
  }

  void test_getConstructors() {
    ClassElementImpl typeElement = class_(name: 'A');
    ConstructorElementImpl constructorOne =
        ElementFactory.constructorElement(typeElement, 'one', false);
    ConstructorElementImpl constructorTwo =
        ElementFactory.constructorElement(typeElement, 'two', false);
    typeElement.constructors = <ConstructorElement>[
      constructorOne,
      constructorTwo
    ];
    InterfaceTypeImpl type = new InterfaceTypeImpl(typeElement);
    expect(type.constructors, hasLength(2));
  }

  void test_getConstructors_empty() {
    ClassElementImpl typeElement = class_(name: 'A');
    typeElement.constructors = const <ConstructorElement>[];
    InterfaceTypeImpl type = new InterfaceTypeImpl(typeElement);
    expect(type.constructors, isEmpty);
  }

  void test_getElement() {
    ClassElementImpl typeElement = class_(name: 'A');
    InterfaceTypeImpl type = new InterfaceTypeImpl(typeElement);
    expect(type.element, typeElement);
  }

  void test_getGetter_implemented() {
    //
    // class A { g {} }
    //
    var classA = class_(name: 'A');
    String getterName = "g";
    PropertyAccessorElement getterG =
        ElementFactory.getterElement(getterName, false, null);
    classA.accessors = <PropertyAccessorElement>[getterG];
    InterfaceType typeA = interfaceType(classA);
    expect(typeA.getGetter(getterName), same(getterG));
  }

  void test_getGetter_parameterized() {
    //
    // class A<E> { E get g {} }
    //
    var AE = typeParameter('E');
    var A = class_(name: 'A', typeParameters: [AE]);

    DartType typeAE = typeParameterType(AE);
    String getterName = "g";
    PropertyAccessorElementImpl getterG =
        ElementFactory.getterElement(getterName, false, typeAE);
    A.accessors = <PropertyAccessorElement>[getterG];
    //
    // A<I>
    //
    InterfaceType I = interfaceType(class_(name: 'I'));
    InterfaceTypeImpl AofI = A.instantiate(
      typeArguments: [I],
      nullabilitySuffix: NullabilitySuffix.star,
    );

    PropertyAccessorElement getter = AofI.getGetter(getterName);
    expect(getter, isNotNull);
    FunctionType getterType = getter.type;
    expect(getterType.returnType, same(I));
  }

  void test_getGetter_unimplemented() {
    //
    // class A {}
    //
    var classA = class_(name: 'A');
    InterfaceType typeA = interfaceType(classA);
    expect(typeA.getGetter("g"), isNull);
  }

  void test_getInterfaces_nonParameterized() {
    //
    // class C implements A, B
    //
    var classA = class_(name: 'A');
    InterfaceType typeA = interfaceType(classA);
    var classB = ElementFactory.classElement2("B");
    InterfaceType typeB = interfaceType(classB);
    var classC = ElementFactory.classElement2("C");
    classC.interfaces = <InterfaceType>[typeA, typeB];
    List<InterfaceType> interfaces = interfaceType(classC).interfaces;
    expect(interfaces, hasLength(2));
    if (identical(interfaces[0], typeA)) {
      expect(interfaces[1], same(typeB));
    } else {
      expect(interfaces[0], same(typeB));
      expect(interfaces[1], same(typeA));
    }
  }

  void test_getInterfaces_parameterized() {
    //
    // class A<E>
    // class B<F> implements A<F>
    //
    var E = typeParameter('E');
    var A = class_(name: 'A', typeParameters: [E]);
    var F = typeParameter('F');
    var B = class_(
      name: 'B',
      typeParameters: [F],
      interfaces: [
        A.instantiate(
          typeArguments: [typeParameterType(F)],
          nullabilitySuffix: NullabilitySuffix.star,
        )
      ],
    );
    //
    // B<I>
    //
    InterfaceType typeI = interfaceType(class_(name: 'I'));
    InterfaceTypeImpl typeBI = interfaceType(B, typeArguments: [typeI]);

    List<InterfaceType> interfaces = typeBI.interfaces;
    expect(interfaces, hasLength(1));
    InterfaceType result = interfaces[0];
    expect(result.element, same(A));
    expect(result.typeArguments[0], same(typeI));
  }

  void test_getMethod_implemented() {
    //
    // class A { m() {} }
    //
    var classA = class_(name: 'A');
    String methodName = "m";
    MethodElementImpl methodM = ElementFactory.methodElement(methodName, null);
    classA.methods = <MethodElement>[methodM];
    InterfaceType typeA = interfaceType(classA);
    expect(typeA.getMethod(methodName), same(methodM));
  }

  void test_getMethod_parameterized_doesNotUseTypeParameter() {
    //
    // class A<E> { B m() {} }
    // class B {}
    //
    var classA = ElementFactory.classElement2("A", ["E"]);
    InterfaceType typeB = interfaceType(class_(name: 'B'));
    String methodName = "m";
    MethodElementImpl methodM =
        ElementFactory.methodElement(methodName, typeB, []);
    classA.methods = <MethodElement>[methodM];
    //
    // A<I>
    //
    InterfaceType typeI = interfaceType(class_(name: 'I'));
    InterfaceTypeImpl typeAI =
        new InterfaceTypeImpl.explicit(classA, <DartType>[typeI]);
    MethodElement method = typeAI.getMethod(methodName);
    expect(method, isNotNull);
    FunctionType methodType = method.type;
    expect(methodType.typeParameters, isEmpty);
    expect(methodType.typeArguments, isEmpty);
  }

  void test_getMethod_parameterized_usesTypeParameter() {
    //
    // class A<E> { E m(E p) {} }
    //
    var E = typeParameter('E');
    var A = class_(name: 'A', typeParameters: [E]);
    DartType typeE = typeParameterType(E);
    String methodName = "m";
    MethodElementImpl methodM =
        ElementFactory.methodElement(methodName, typeE, [typeE]);
    A.methods = <MethodElement>[methodM];
    //
    // A<I>
    //
    InterfaceType typeI = interfaceType(class_(name: 'I'));
    InterfaceTypeImpl typeAI =
        new InterfaceTypeImpl.explicit(A, <DartType>[typeI]);
    MethodElement method = typeAI.getMethod(methodName);
    expect(method, isNotNull);
    FunctionType methodType = method.type;
    expect(methodType.typeParameters, isEmpty);
    expect(methodType.typeArguments, isEmpty);
    expect(methodType.returnType, same(typeI));
    List<DartType> parameterTypes = methodType.normalParameterTypes;
    expect(parameterTypes, hasLength(1));
    expect(parameterTypes[0], same(typeI));
  }

  void test_getMethod_unimplemented() {
    //
    // class A {}
    //
    var classA = class_(name: 'A');
    InterfaceType typeA = interfaceType(classA);
    expect(typeA.getMethod("m"), isNull);
  }

  void test_getMethods() {
    ClassElementImpl typeElement = class_(name: 'A');
    MethodElementImpl methodOne = ElementFactory.methodElement("one", null);
    MethodElementImpl methodTwo = ElementFactory.methodElement("two", null);
    typeElement.methods = <MethodElement>[methodOne, methodTwo];
    InterfaceTypeImpl type = new InterfaceTypeImpl(typeElement);
    expect(type.methods.length, 2);
  }

  void test_getMethods_empty() {
    ClassElementImpl typeElement = class_(name: 'A');
    InterfaceTypeImpl type = new InterfaceTypeImpl(typeElement);
    expect(type.methods.length, 0);
  }

  void test_getMixins_nonParameterized() {
    //
    // class C extends Object with A, B
    //
    var classA = class_(name: 'A');
    InterfaceType typeA = interfaceType(classA);
    var classB = ElementFactory.classElement2("B");
    InterfaceType typeB = interfaceType(classB);
    var classC = ElementFactory.classElement2("C");
    classC.mixins = <InterfaceType>[typeA, typeB];
    List<InterfaceType> interfaces = interfaceType(classC).mixins;
    expect(interfaces, hasLength(2));
    if (identical(interfaces[0], typeA)) {
      expect(interfaces[1], same(typeB));
    } else {
      expect(interfaces[0], same(typeB));
      expect(interfaces[1], same(typeA));
    }
  }

  void test_getMixins_parameterized() {
    //
    // class A<E>
    // class B<F> extends Object with A<F>
    //
    var E = typeParameter('E');
    var A = class_(name: 'A', typeParameters: [E]);

    var F = typeParameter('F');
    var B = class_(
      name: 'B',
      typeParameters: [F],
      mixins: [
        interfaceType(A, typeArguments: [
          typeParameterType(F),
        ]),
      ],
    );
    //
    // B<I>
    //
    InterfaceType typeI = interfaceType(class_(name: 'I'));
    InterfaceTypeImpl typeBI =
        new InterfaceTypeImpl.explicit(B, <DartType>[typeI]);
    List<InterfaceType> interfaces = typeBI.mixins;
    expect(interfaces, hasLength(1));
    InterfaceType result = interfaces[0];
    expect(result.element, same(A));
    expect(result.typeArguments[0], same(typeI));
  }

  void test_getSetter_implemented() {
    //
    // class A { s() {} }
    //
    var classA = class_(name: 'A');
    String setterName = "s";
    PropertyAccessorElement setterS =
        ElementFactory.setterElement(setterName, false, null);
    classA.accessors = <PropertyAccessorElement>[setterS];
    InterfaceType typeA = interfaceType(classA);
    expect(typeA.getSetter(setterName), same(setterS));
  }

  void test_getSetter_parameterized() {
    //
    // class A<E> { set s(E p) {} }
    //
    var E = typeParameter('E');
    var A = class_(name: 'A', typeParameters: [E]);
    DartType typeE = typeParameterType(E);
    String setterName = "s";
    PropertyAccessorElementImpl setterS =
        ElementFactory.setterElement(setterName, false, typeE);
    A.accessors = <PropertyAccessorElement>[setterS];
    //
    // A<I>
    //
    InterfaceType typeI = interfaceType(class_(name: 'I'));
    InterfaceTypeImpl typeAI =
        new InterfaceTypeImpl.explicit(A, <DartType>[typeI]);
    PropertyAccessorElement setter = typeAI.getSetter(setterName);
    expect(setter, isNotNull);
    FunctionType setterType = setter.type;
    List<DartType> parameterTypes = setterType.normalParameterTypes;
    expect(parameterTypes, hasLength(1));
    expect(parameterTypes[0], same(typeI));
  }

  void test_getSetter_unimplemented() {
    //
    // class A {}
    //
    var classA = class_(name: 'A');
    InterfaceType typeA = interfaceType(classA);
    expect(typeA.getSetter("s"), isNull);
  }

  void test_getSuperclass_nonParameterized() {
    //
    // class B extends A
    //
    var classA = class_(name: 'A');
    InterfaceType typeA = interfaceType(classA);
    var classB = ElementFactory.classElement("B", typeA);
    InterfaceType typeB = interfaceType(classB);
    expect(typeB.superclass, same(typeA));
  }

  void test_getSuperclass_parameterized() {
    //
    // class A<E>
    // class B<F> extends A<F>
    //
    var E = typeParameter('E');
    var A = class_(name: 'A', typeParameters: [E]);

    var F = typeParameter('F');
    var typeF = typeParameterType(F);

    var B = class_(
      name: 'B',
      typeParameters: [F],
      superType: interfaceType(A, typeArguments: [typeF]),
    );

    var classB = B;
    //
    // B<I>
    //
    InterfaceType typeI = interfaceType(class_(name: 'I'));
    InterfaceTypeImpl typeBI =
        new InterfaceTypeImpl.explicit(classB, <DartType>[typeI]);
    InterfaceType superclass = typeBI.superclass;
    expect(superclass.element, same(A));
    expect(superclass.typeArguments[0], same(typeI));
  }

  void test_getTypeArguments_empty() {
    InterfaceType type = interfaceType(ElementFactory.classElement2('A'));
    expect(type.typeArguments, hasLength(0));
  }

  void test_hashCode() {
    ClassElement classA = class_(name: 'A');
    InterfaceType typeA = interfaceType(classA);
    expect(0 == typeA.hashCode, isFalse);
  }

  void test_lookUpGetter_implemented() {
    //
    // class A { g {} }
    //
    var classA = class_(name: 'A');
    String getterName = "g";
    PropertyAccessorElement getterG =
        ElementFactory.getterElement(getterName, false, null);
    classA.accessors = <PropertyAccessorElement>[getterG];
    InterfaceType typeA = interfaceType(classA);
    LibraryElementImpl library =
        ElementFactory.library(_analysisContext, "lib");
    CompilationUnitElement unit = library.definingCompilationUnit;
    (unit as CompilationUnitElementImpl).types = <ClassElement>[classA];
    expect(typeA.lookUpGetter(getterName, library), same(getterG));
  }

  void test_lookUpGetter_inherited() {
    //
    // class A { g {} }
    // class B extends A {}
    //
    var classA = class_(name: 'A');
    String getterName = "g";
    PropertyAccessorElement getterG =
        ElementFactory.getterElement(getterName, false, null);
    classA.accessors = <PropertyAccessorElement>[getterG];
    ClassElementImpl classB =
        ElementFactory.classElement("B", interfaceType(classA));
    InterfaceType typeB = interfaceType(classB);
    LibraryElementImpl library =
        ElementFactory.library(_analysisContext, "lib");
    CompilationUnitElement unit = library.definingCompilationUnit;
    (unit as CompilationUnitElementImpl).types = <ClassElement>[classA, classB];
    expect(typeB.lookUpGetter(getterName, library), same(getterG));
  }

  void test_lookUpGetter_mixin_shadowing() {
    //
    // class B {}
    // class M1 { get g {} }
    // class M2 { get g {} }
    // class C extends B with M1, M2 {}
    //
    TestTypeProvider typeProvider = new TestTypeProvider();
    String getterName = 'g';
    var classB = class_(name: 'B');
    ClassElementImpl classM1 = ElementFactory.classElement2('M1');
    PropertyAccessorElementImpl getterM1g = ElementFactory.getterElement(
        getterName, false, typeProvider.dynamicType);
    classM1.accessors = <PropertyAccessorElement>[getterM1g];
    ClassElementImpl classM2 = ElementFactory.classElement2('M2');
    PropertyAccessorElementImpl getterM2g = ElementFactory.getterElement(
        getterName, false, typeProvider.dynamicType);
    classM2.accessors = <PropertyAccessorElement>[getterM2g];
    ClassElementImpl classC =
        ElementFactory.classElement('C', interfaceType(classB));
    classC.mixins = <InterfaceType>[
      interfaceType(classM1),
      interfaceType(classM2)
    ];
    LibraryElementImpl library =
        ElementFactory.library(_analysisContext, "lib");
    CompilationUnitElementImpl unit = library.definingCompilationUnit;
    unit.types = <ClassElement>[classB, classM1, classM2, classC];
    expect(interfaceType(classC).lookUpGetter(getterName, library), getterM2g);
  }

  void test_lookUpGetter_recursive() {
    //
    // class A extends B {}
    // class B extends A {}
    //
    var classA = class_(name: 'A');
    InterfaceType typeA = interfaceType(classA);
    var classB = ElementFactory.classElement("B", typeA);
    classA.supertype = interfaceType(classB);
    LibraryElementImpl library =
        ElementFactory.library(_analysisContext, "lib");
    CompilationUnitElement unit = library.definingCompilationUnit;
    (unit as CompilationUnitElementImpl).types = <ClassElement>[classA, classB];
    expect(typeA.lookUpGetter("g", library), isNull);
  }

  void test_lookUpGetter_unimplemented() {
    //
    // class A {}
    //
    var classA = class_(name: 'A');
    InterfaceType typeA = interfaceType(classA);
    LibraryElementImpl library =
        ElementFactory.library(_analysisContext, "lib");
    CompilationUnitElement unit = library.definingCompilationUnit;
    (unit as CompilationUnitElementImpl).types = <ClassElement>[classA];
    expect(typeA.lookUpGetter("g", library), isNull);
  }

  void test_lookUpMethod_implemented() {
    //
    // class A { m() {} }
    //
    var classA = class_(name: 'A');
    String methodName = "m";
    MethodElementImpl methodM = ElementFactory.methodElement(methodName, null);
    classA.methods = <MethodElement>[methodM];
    InterfaceType typeA = interfaceType(classA);
    LibraryElementImpl library =
        ElementFactory.library(_analysisContext, "lib");
    CompilationUnitElement unit = library.definingCompilationUnit;
    (unit as CompilationUnitElementImpl).types = <ClassElement>[classA];
    expect(typeA.lookUpMethod(methodName, library), same(methodM));
  }

  void test_lookUpMethod_inherited() {
    //
    // class A { m() {} }
    // class B extends A {}
    //
    var classA = class_(name: 'A');
    String methodName = "m";
    MethodElementImpl methodM = ElementFactory.methodElement(methodName, null);
    classA.methods = <MethodElement>[methodM];
    ClassElementImpl classB =
        ElementFactory.classElement("B", interfaceType(classA));
    InterfaceType typeB = interfaceType(classB);
    LibraryElementImpl library =
        ElementFactory.library(_analysisContext, "lib");
    CompilationUnitElement unit = library.definingCompilationUnit;
    (unit as CompilationUnitElementImpl).types = <ClassElement>[classA, classB];
    expect(typeB.lookUpMethod(methodName, library), same(methodM));
  }

  void test_lookUpMethod_mixin_shadowing() {
    //
    // class B {}
    // class M1 { m() {} }
    // class M2 { m() {} }
    // class C extends B with M1, M2 {}
    //
    String methodName = 'm';
    var classB = class_(name: 'B');
    ClassElementImpl classM1 = ElementFactory.classElement2('M1');
    MethodElementImpl methodM1m =
        ElementFactory.methodElement(methodName, null);
    classM1.methods = <MethodElement>[methodM1m];
    ClassElementImpl classM2 = ElementFactory.classElement2('M2');
    MethodElementImpl methodM2m =
        ElementFactory.methodElement(methodName, null);
    classM2.methods = <MethodElement>[methodM2m];
    ClassElementImpl classC =
        ElementFactory.classElement('C', interfaceType(classB));
    classC.mixins = <InterfaceType>[
      interfaceType(classM1),
      interfaceType(classM2)
    ];
    LibraryElementImpl library =
        ElementFactory.library(_analysisContext, "lib");
    CompilationUnitElementImpl unit = library.definingCompilationUnit;
    unit.types = <ClassElement>[classB, classM1, classM2, classC];
    expect(interfaceType(classC).lookUpMethod(methodName, library), methodM2m);
  }

  void test_lookUpMethod_parameterized() {
    //
    // class A<E> { E m(E p) {} }
    // class B<F> extends A<F> {}
    //
    var E = typeParameter('E');
    var A = class_(name: 'A', typeParameters: [E]);
    DartType typeE = typeParameterType(E);
    String methodName = "m";
    MethodElementImpl methodM =
        ElementFactory.methodElement(methodName, typeE, [typeE]);
    A.methods = <MethodElement>[methodM];

    var F = typeParameter('F');
    var B = class_(
      name: 'B',
      typeParameters: [F],
      superType: interfaceType(A, typeArguments: [
        typeParameterType(F),
      ]),
    );
    LibraryElementImpl library =
        ElementFactory.library(_analysisContext, "lib");
    CompilationUnitElement unit = library.definingCompilationUnit;
    (unit as CompilationUnitElementImpl).types = <ClassElement>[A];
    //
    // B<I>
    //
    InterfaceType typeI = interfaceType(class_(name: 'I'));
    InterfaceTypeImpl typeBI =
        new InterfaceTypeImpl.explicit(B, <DartType>[typeI]);
    MethodElement method = typeBI.lookUpMethod(methodName, library);
    expect(method, isNotNull);
    FunctionType methodType = method.type;
    expect(methodType.returnType, same(typeI));
    List<DartType> parameterTypes = methodType.normalParameterTypes;
    expect(parameterTypes, hasLength(1));
    expect(parameterTypes[0], same(typeI));
  }

  void test_lookUpMethod_recursive() {
    //
    // class A extends B {}
    // class B extends A {}
    //
    var classA = class_(name: 'A');
    InterfaceType typeA = interfaceType(classA);
    var classB = ElementFactory.classElement("B", typeA);
    classA.supertype = interfaceType(classB);
    LibraryElementImpl library =
        ElementFactory.library(_analysisContext, "lib");
    CompilationUnitElement unit = library.definingCompilationUnit;
    (unit as CompilationUnitElementImpl).types = <ClassElement>[classA, classB];
    expect(typeA.lookUpMethod("m", library), isNull);
  }

  void test_lookUpMethod_unimplemented() {
    //
    // class A {}
    //
    var classA = class_(name: 'A');
    InterfaceType typeA = interfaceType(classA);
    LibraryElementImpl library =
        ElementFactory.library(_analysisContext, "lib");
    CompilationUnitElement unit = library.definingCompilationUnit;
    (unit as CompilationUnitElementImpl).types = <ClassElement>[classA];
    expect(typeA.lookUpMethod("m", library), isNull);
  }

  void test_lookUpSetter_implemented() {
    //
    // class A { s(x) {} }
    //
    var classA = class_(name: 'A');
    String setterName = "s";
    PropertyAccessorElement setterS =
        ElementFactory.setterElement(setterName, false, null);
    classA.accessors = <PropertyAccessorElement>[setterS];
    InterfaceType typeA = interfaceType(classA);
    LibraryElementImpl library =
        ElementFactory.library(_analysisContext, "lib");
    CompilationUnitElement unit = library.definingCompilationUnit;
    (unit as CompilationUnitElementImpl).types = <ClassElement>[classA];
    expect(typeA.lookUpSetter(setterName, library), same(setterS));
  }

  void test_lookUpSetter_inherited() {
    //
    // class A { s(x) {} }
    // class B extends A {}
    //
    var classA = class_(name: 'A');
    String setterName = "g";
    PropertyAccessorElement setterS =
        ElementFactory.setterElement(setterName, false, null);
    classA.accessors = <PropertyAccessorElement>[setterS];
    ClassElementImpl classB =
        ElementFactory.classElement("B", interfaceType(classA));
    InterfaceType typeB = interfaceType(classB);
    LibraryElementImpl library =
        ElementFactory.library(_analysisContext, "lib");
    CompilationUnitElement unit = library.definingCompilationUnit;
    (unit as CompilationUnitElementImpl).types = <ClassElement>[classA, classB];
    expect(typeB.lookUpSetter(setterName, library), same(setterS));
  }

  void test_lookUpSetter_mixin_shadowing() {
    //
    // class B {}
    // class M1 { set s() {} }
    // class M2 { set s() {} }
    // class C extends B with M1, M2 {}
    //
    TestTypeProvider typeProvider = new TestTypeProvider();
    String setterName = 's';
    var classB = class_(name: 'B');
    ClassElementImpl classM1 = ElementFactory.classElement2('M1');
    PropertyAccessorElementImpl setterM1g = ElementFactory.setterElement(
        setterName, false, typeProvider.dynamicType);
    classM1.accessors = <PropertyAccessorElement>[setterM1g];
    ClassElementImpl classM2 = ElementFactory.classElement2('M2');
    PropertyAccessorElementImpl setterM2g = ElementFactory.getterElement(
        setterName, false, typeProvider.dynamicType);
    classM2.accessors = <PropertyAccessorElement>[setterM2g];
    ClassElementImpl classC =
        ElementFactory.classElement('C', interfaceType(classB));
    classC.mixins = <InterfaceType>[
      interfaceType(classM1),
      interfaceType(classM2)
    ];
    LibraryElementImpl library =
        ElementFactory.library(_analysisContext, "lib");
    CompilationUnitElementImpl unit = library.definingCompilationUnit;
    unit.types = <ClassElement>[classB, classM1, classM2, classC];
    expect(interfaceType(classC).lookUpGetter(setterName, library), setterM2g);
  }

  void test_lookUpSetter_recursive() {
    //
    // class A extends B {}
    // class B extends A {}
    //
    var classA = class_(name: 'A');
    InterfaceType typeA = interfaceType(classA);
    var classB = ElementFactory.classElement("B", typeA);
    classA.supertype = interfaceType(classB);
    LibraryElementImpl library =
        ElementFactory.library(_analysisContext, "lib");
    CompilationUnitElement unit = library.definingCompilationUnit;
    (unit as CompilationUnitElementImpl).types = <ClassElement>[classA, classB];
    expect(typeA.lookUpSetter("s", library), isNull);
  }

  void test_lookUpSetter_unimplemented() {
    //
    // class A {}
    //
    var classA = class_(name: 'A');
    InterfaceType typeA = interfaceType(classA);
    LibraryElementImpl library =
        ElementFactory.library(_analysisContext, "lib");
    CompilationUnitElement unit = library.definingCompilationUnit;
    (unit as CompilationUnitElementImpl).types = <ClassElement>[classA];
    expect(typeA.lookUpSetter("s", library), isNull);
  }

  void test_resolveToBound() {
    InterfaceTypeImpl type = interfaceType(ElementFactory.classElement2('A'));

    // Returns this.
    expect(type.resolveToBound(null), same(type));
  }

  @deprecated
  void test_substitute_exception() {
    try {
      var classA = class_(name: 'A');
      InterfaceTypeImpl type = new InterfaceTypeImpl(classA);
      InterfaceType argumentType = interfaceType(class_(name: 'B'));
      type.substitute2(<DartType>[argumentType], <DartType>[]);
      fail(
          "Expected to encounter exception, argument and parameter type array lengths not equal.");
    } catch (e) {
      // Expected result
    }
  }

  @deprecated
  void test_substitute_notEqual() {
    // The [test_substitute_equals] above has a slightly higher level
    // implementation.
    var classA = class_(name: 'A');
    TypeParameterElementImpl parameterElement =
        new TypeParameterElementImpl.forNode(AstTestFactory.identifier3("E"));
    TypeParameterTypeImpl parameter =
        new TypeParameterTypeImpl(parameterElement);
    InterfaceTypeImpl type =
        new InterfaceTypeImpl.explicit(classA, <DartType>[parameter]);
    InterfaceType argumentType = interfaceType(class_(name: 'B'));
    TypeParameterTypeImpl parameterType = new TypeParameterTypeImpl(
        new TypeParameterElementImpl.forNode(AstTestFactory.identifier3("F")));
    InterfaceType result =
        type.substitute2(<DartType>[argumentType], <DartType>[parameterType]);
    expect(result.element, classA);
    List<DartType> resultArguments = result.typeArguments;
    expect(resultArguments, hasLength(1));
    expect(resultArguments[0], parameter);
  }
}

@reflectiveTest
class LibraryElementImplTest {
  void test_creation() {
    expect(
        new LibraryElementImpl.forNode(TestAnalysisContext(), null,
            AstTestFactory.libraryIdentifier2(["l"]), true),
        isNotNull);
  }

  void test_getImportedLibraries() {
    AnalysisContext context = TestAnalysisContext();
    LibraryElementImpl library1 = ElementFactory.library(context, "l1");
    LibraryElementImpl library2 = ElementFactory.library(context, "l2");
    LibraryElementImpl library3 = ElementFactory.library(context, "l3");
    LibraryElementImpl library4 = ElementFactory.library(context, "l4");
    PrefixElement prefixA =
        new PrefixElementImpl.forNode(AstTestFactory.identifier3("a"));
    PrefixElement prefixB =
        new PrefixElementImpl.forNode(AstTestFactory.identifier3("b"));
    List<ImportElementImpl> imports = [
      ElementFactory.importFor(library2, null),
      ElementFactory.importFor(library2, prefixB),
      ElementFactory.importFor(library3, null),
      ElementFactory.importFor(library3, prefixA),
      ElementFactory.importFor(library3, prefixB),
      ElementFactory.importFor(library4, prefixA)
    ];
    library1.imports = imports;
    List<LibraryElement> libraries = library1.importedLibraries;
    expect(libraries,
        unorderedEquals(<LibraryElement>[library2, library3, library4]));
  }

  void test_getPrefixes() {
    AnalysisContext context = TestAnalysisContext();
    LibraryElementImpl library = ElementFactory.library(context, "l1");
    PrefixElement prefixA =
        new PrefixElementImpl.forNode(AstTestFactory.identifier3("a"));
    PrefixElement prefixB =
        new PrefixElementImpl.forNode(AstTestFactory.identifier3("b"));
    List<ImportElementImpl> imports = [
      ElementFactory.importFor(ElementFactory.library(context, "l2"), null),
      ElementFactory.importFor(ElementFactory.library(context, "l3"), null),
      ElementFactory.importFor(ElementFactory.library(context, "l4"), prefixA),
      ElementFactory.importFor(ElementFactory.library(context, "l5"), prefixA),
      ElementFactory.importFor(ElementFactory.library(context, "l6"), prefixB)
    ];
    library.imports = imports;
    List<PrefixElement> prefixes = library.prefixes;
    expect(prefixes, hasLength(2));
    if (identical(prefixA, prefixes[0])) {
      expect(prefixes[1], same(prefixB));
    } else {
      expect(prefixes[0], same(prefixB));
      expect(prefixes[1], same(prefixA));
    }
  }

  void test_getUnits() {
    AnalysisContext context = TestAnalysisContext();
    LibraryElementImpl library = ElementFactory.library(context, "test");
    CompilationUnitElement unitLib = library.definingCompilationUnit;
    CompilationUnitElementImpl unitA =
        ElementFactory.compilationUnit("unit_a.dart", unitLib.source);
    CompilationUnitElementImpl unitB =
        ElementFactory.compilationUnit("unit_b.dart", unitLib.source);
    library.parts = <CompilationUnitElement>[unitA, unitB];
    expect(library.units,
        unorderedEquals(<CompilationUnitElement>[unitLib, unitA, unitB]));
  }

  void test_setImports() {
    AnalysisContext context = TestAnalysisContext();
    LibraryElementImpl library = new LibraryElementImpl.forNode(
        context, null, AstTestFactory.libraryIdentifier2(["l1"]), true);
    List<ImportElementImpl> expectedImports = [
      ElementFactory.importFor(ElementFactory.library(context, "l2"), null),
      ElementFactory.importFor(ElementFactory.library(context, "l3"), null)
    ];
    library.imports = expectedImports;
    List<ImportElement> actualImports = library.imports;
    expect(actualImports, hasLength(expectedImports.length));
    for (int i = 0; i < actualImports.length; i++) {
      expect(actualImports[i], same(expectedImports[i]));
    }
  }
}

@reflectiveTest
class TopLevelVariableElementImplTest extends DriverResolutionTest {
  test_computeConstantValue() async {
    newFile('/test/lib/a.dart', content: r'''
const int C = 42;
''');
    await resolveTestCode(r'''
import 'a.dart';
main() {
  print(C);
}
''');
    SimpleIdentifier argument = findNode.simple('C);');
    PropertyAccessorElementImpl getter = argument.staticElement;
    TopLevelVariableElement constant = getter.variable;
    expect(constant.constantValue, isNull);

    DartObject value = constant.computeConstantValue();
    expect(value, isNotNull);
    expect(value.toIntValue(), 42);
    expect(constant.constantValue, value);
  }
}

@reflectiveTest
class TypeParameterTypeImplTest extends AbstractTypeTest {
  void test_creation() {
    expect(
        new TypeParameterTypeImpl(new TypeParameterElementImpl.forNode(
            AstTestFactory.identifier3("E"))),
        isNotNull);
  }

  void test_getElement() {
    TypeParameterElementImpl element =
        new TypeParameterElementImpl.forNode(AstTestFactory.identifier3("E"));
    TypeParameterTypeImpl type = new TypeParameterTypeImpl(element);
    expect(type.element, element);
  }

  void test_resolveToBound_bound() {
    ClassElementImpl classS = class_(name: 'A');
    TypeParameterElementImpl element =
        new TypeParameterElementImpl.forNode(AstTestFactory.identifier3("E"));
    element.bound = interfaceType(classS);
    TypeParameterTypeImpl type = new TypeParameterTypeImpl(element);
    expect(type.resolveToBound(null), interfaceType(classS));
  }

  void test_resolveToBound_bound_nullableInner() {
    ClassElementImpl classS = class_(name: 'A');
    TypeParameterElementImpl element =
        new TypeParameterElementImpl.forNode(AstTestFactory.identifier3("E"));
    element.bound = (interfaceType(classS) as TypeImpl)
        .withNullability(NullabilitySuffix.question);
    TypeParameterTypeImpl type = new TypeParameterTypeImpl(element);
    expect(type.resolveToBound(null), same(element.bound));
  }

  void test_resolveToBound_bound_nullableInnerOuter() {
    ClassElementImpl classS = class_(name: 'A');
    TypeParameterElementImpl element =
        new TypeParameterElementImpl.forNode(AstTestFactory.identifier3("E"));
    element.bound = (interfaceType(classS) as TypeImpl)
        .withNullability(NullabilitySuffix.question);
    TypeParameterTypeImpl type = new TypeParameterTypeImpl(element)
        .withNullability(NullabilitySuffix.question);
    expect(type.resolveToBound(null), same(element.bound));
  }

  void test_resolveToBound_bound_nullableInnerStarOuter() {
    ClassElementImpl classS = class_(name: 'A');
    TypeParameterElementImpl element =
        new TypeParameterElementImpl.forNode(AstTestFactory.identifier3("E"));
    element.bound = (interfaceType(classS) as TypeImpl)
        .withNullability(NullabilitySuffix.star);
    TypeParameterTypeImpl type = new TypeParameterTypeImpl(element)
        .withNullability(NullabilitySuffix.question);
    expect(
        type.resolveToBound(null),
        equals((interfaceType(classS) as TypeImpl)
            .withNullability(NullabilitySuffix.question)));
  }

  void test_resolveToBound_bound_nullableOuter() {
    ClassElementImpl classS = class_(name: 'A');
    TypeParameterElementImpl element =
        new TypeParameterElementImpl.forNode(AstTestFactory.identifier3("E"));
    element.bound = interfaceType(classS);
    TypeParameterTypeImpl type = new TypeParameterTypeImpl(element)
        .withNullability(NullabilitySuffix.question);
    expect(
        type.resolveToBound(null),
        equals((interfaceType(classS) as TypeImpl)
            .withNullability(NullabilitySuffix.question)));
  }

  void test_resolveToBound_bound_starInner() {
    ClassElementImpl classS = class_(name: 'A');
    TypeParameterElementImpl element =
        new TypeParameterElementImpl.forNode(AstTestFactory.identifier3("E"));
    element.bound = (interfaceType(classS) as TypeImpl)
        .withNullability(NullabilitySuffix.star);
    TypeParameterTypeImpl type = new TypeParameterTypeImpl(element);
    expect(type.resolveToBound(null), same(element.bound));
  }

  void test_resolveToBound_bound_starInnerNullableOuter() {
    ClassElementImpl classS = class_(name: 'A');
    TypeParameterElementImpl element =
        new TypeParameterElementImpl.forNode(AstTestFactory.identifier3("E"));
    element.bound = (interfaceType(classS) as TypeImpl)
        .withNullability(NullabilitySuffix.question);
    TypeParameterTypeImpl type = new TypeParameterTypeImpl(element)
        .withNullability(NullabilitySuffix.star);
    expect(type.resolveToBound(null), same(element.bound));
  }

  void test_resolveToBound_bound_starOuter() {
    ClassElementImpl classS = class_(name: 'A');
    TypeParameterElementImpl element =
        new TypeParameterElementImpl.forNode(AstTestFactory.identifier3("E"));
    element.bound = interfaceType(classS);
    TypeParameterTypeImpl type = new TypeParameterTypeImpl(element)
        .withNullability(NullabilitySuffix.star);
    expect(
        type.resolveToBound(null),
        (interfaceType(classS) as TypeImpl)
            .withNullability(NullabilitySuffix.star));
  }

  void test_resolveToBound_nestedBound() {
    ClassElementImpl classS = class_(name: 'A');
    TypeParameterElementImpl elementE =
        new TypeParameterElementImpl.forNode(AstTestFactory.identifier3("E"));
    elementE.bound = interfaceType(classS);
    TypeParameterTypeImpl typeE = new TypeParameterTypeImpl(elementE);
    TypeParameterElementImpl elementF =
        new TypeParameterElementImpl.forNode(AstTestFactory.identifier3("F"));
    elementF.bound = typeE;
    TypeParameterTypeImpl typeF = new TypeParameterTypeImpl(elementE);
    expect(typeF.resolveToBound(null), interfaceType(classS));
  }

  void test_resolveToBound_unbound() {
    TypeParameterTypeImpl type = new TypeParameterTypeImpl(
        new TypeParameterElementImpl.forNode(AstTestFactory.identifier3("E")));
    // Returns whatever type is passed to resolveToBound().
    expect(type.resolveToBound(VoidTypeImpl.instance),
        same(VoidTypeImpl.instance));
  }

  @deprecated
  void test_substitute_equal() {
    TypeParameterElementImpl element =
        new TypeParameterElementImpl.forNode(AstTestFactory.identifier3("E"));
    TypeParameterTypeImpl type = new TypeParameterTypeImpl(element);
    InterfaceTypeImpl argument = new InterfaceTypeImpl(
        new ClassElementImpl.forNode(AstTestFactory.identifier3("A")));
    TypeParameterTypeImpl parameter = new TypeParameterTypeImpl(element);
    expect(type.substitute2(<DartType>[argument], <DartType>[parameter]),
        same(argument));
  }

  @deprecated
  void test_substitute_notEqual() {
    TypeParameterTypeImpl type = new TypeParameterTypeImpl(
        new TypeParameterElementImpl.forNode(AstTestFactory.identifier3("E")));
    InterfaceTypeImpl argument = new InterfaceTypeImpl(
        new ClassElementImpl.forNode(AstTestFactory.identifier3("A")));
    TypeParameterTypeImpl parameter = new TypeParameterTypeImpl(
        new TypeParameterElementImpl.forNode(AstTestFactory.identifier3("F")));
    expect(type.substitute2(<DartType>[argument], <DartType>[parameter]),
        same(type));
  }
}

@reflectiveTest
class VoidTypeImplTest extends AbstractTypeTest {
  /**
   * Reference {code VoidTypeImpl.getInstance()}.
   */
  DartType _voidType = VoidTypeImpl.instance;

  void test_isVoid() {
    expect(_voidType.isVoid, isTrue);
  }

  void test_resolveToBound() {
    // Returns this.
    expect(_voidType.resolveToBound(null), same(_voidType));
  }
}
