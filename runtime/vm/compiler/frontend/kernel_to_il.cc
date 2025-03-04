// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

#include "vm/compiler/frontend/kernel_to_il.h"

#include "platform/assert.h"
#include "vm/compiler/aot/precompiler.h"
#include "vm/compiler/backend/il.h"
#include "vm/compiler/backend/il_printer.h"
#include "vm/compiler/backend/locations.h"
#include "vm/compiler/ffi.h"
#include "vm/compiler/frontend/kernel_binary_flowgraph.h"
#include "vm/compiler/frontend/kernel_translation_helper.h"
#include "vm/compiler/frontend/prologue_builder.h"
#include "vm/compiler/jit/compiler.h"
#include "vm/kernel_loader.h"
#include "vm/longjump.h"
#include "vm/native_entry.h"
#include "vm/object_store.h"
#include "vm/report.h"
#include "vm/resolver.h"
#include "vm/stack_frame.h"

#if !defined(DART_PRECOMPILED_RUNTIME)

namespace dart {
namespace kernel {

#define Z (zone_)
#define H (translation_helper_)
#define T (type_translator_)
#define I Isolate::Current()

FlowGraphBuilder::FlowGraphBuilder(
    ParsedFunction* parsed_function,
    ZoneGrowableArray<const ICData*>* ic_data_array,
    ZoneGrowableArray<intptr_t>* context_level_array,
    InlineExitCollector* exit_collector,
    bool optimizing,
    intptr_t osr_id,
    intptr_t first_block_id,
    bool inlining_unchecked_entry,
    GrowableObjectArray* record_yield_positions)
    : BaseFlowGraphBuilder(parsed_function,
                           first_block_id - 1,
                           osr_id,
                           context_level_array,
                           exit_collector,
                           inlining_unchecked_entry),
      translation_helper_(Thread::Current()),
      thread_(translation_helper_.thread()),
      zone_(translation_helper_.zone()),
      parsed_function_(parsed_function),
      optimizing_(optimizing),
      ic_data_array_(*ic_data_array),
      next_function_id_(0),
      loop_depth_(0),
      try_depth_(0),
      catch_depth_(0),
      for_in_depth_(0),
      block_expression_depth_(0),
      graph_entry_(NULL),
      scopes_(NULL),
      breakable_block_(NULL),
      switch_block_(NULL),
      try_catch_block_(NULL),
      try_finally_block_(NULL),
      catch_block_(NULL) {
  const Script& script =
      Script::Handle(Z, parsed_function->function().script());
  record_yield_positions_ = record_yield_positions;
  H.InitFromScript(script);
}

FlowGraphBuilder::~FlowGraphBuilder() {}

Fragment FlowGraphBuilder::EnterScope(
    intptr_t kernel_offset,
    const LocalScope** context_scope /* = nullptr */) {
  Fragment instructions;
  const LocalScope* scope = scopes_->scopes.Lookup(kernel_offset);
  if (scope->num_context_variables() > 0) {
    instructions += PushContext(scope);
    instructions += Drop();
  }
  if (context_scope != nullptr) {
    *context_scope = scope;
  }
  return instructions;
}

Fragment FlowGraphBuilder::ExitScope(intptr_t kernel_offset) {
  Fragment instructions;
  const intptr_t context_size =
      scopes_->scopes.Lookup(kernel_offset)->num_context_variables();
  if (context_size > 0) {
    instructions += PopContext();
  }
  return instructions;
}

Fragment FlowGraphBuilder::AdjustContextTo(int depth) {
  ASSERT(depth <= context_depth_ && depth >= 0);
  Fragment instructions;
  if (depth < context_depth_) {
    instructions += LoadContextAt(depth);
    instructions += StoreLocal(TokenPosition::kNoSource,
                               parsed_function_->current_context_var());
    instructions += Drop();
    context_depth_ = depth;
  }
  return instructions;
}

Fragment FlowGraphBuilder::PushContext(const LocalScope* scope) {
  ASSERT(scope->num_context_variables() > 0);
  Fragment instructions = AllocateContext(scope->context_slots());
  LocalVariable* context = MakeTemporary();
  instructions += LoadLocal(context);
  instructions += LoadLocal(parsed_function_->current_context_var());
  instructions +=
      StoreInstanceField(TokenPosition::kNoSource, Slot::Context_parent(),
                         StoreInstanceFieldInstr::Kind::kInitializing);
  instructions += StoreLocal(TokenPosition::kNoSource,
                             parsed_function_->current_context_var());
  ++context_depth_;
  return instructions;
}

Fragment FlowGraphBuilder::PopContext() {
  return AdjustContextTo(context_depth_ - 1);
}

Fragment FlowGraphBuilder::LoadInstantiatorTypeArguments() {
  // TODO(27590): We could use `active_class_->IsGeneric()`.
  Fragment instructions;
  if (scopes_ != nullptr && scopes_->type_arguments_variable != nullptr) {
#ifdef DEBUG
    Function& function =
        Function::Handle(Z, parsed_function_->function().raw());
    while (function.IsClosureFunction()) {
      function = function.parent_function();
    }
    ASSERT(function.IsFactory());
#endif
    instructions += LoadLocal(scopes_->type_arguments_variable);
  } else if (parsed_function_->has_receiver_var() &&
             active_class_.ClassNumTypeArguments() > 0) {
    ASSERT(!parsed_function_->function().IsFactory());
    instructions += LoadLocal(parsed_function_->receiver_var());
    instructions += LoadNativeField(
        Slot::GetTypeArgumentsSlotFor(thread_, *active_class_.klass));
  } else {
    instructions += NullConstant();
  }
  return instructions;
}

// This function is responsible for pushing a type arguments vector which
// contains all type arguments of enclosing functions prepended to the type
// arguments of the current function.
Fragment FlowGraphBuilder::LoadFunctionTypeArguments() {
  Fragment instructions;

  const Function& function = parsed_function_->function();

  if (function.IsGeneric() || function.HasGenericParent()) {
    ASSERT(parsed_function_->function_type_arguments() != NULL);
    instructions += LoadLocal(parsed_function_->function_type_arguments());
  } else {
    instructions += NullConstant();
  }

  return instructions;
}

Fragment FlowGraphBuilder::TranslateInstantiatedTypeArguments(
    const TypeArguments& type_arguments) {
  Fragment instructions;

  if (type_arguments.IsNull() || type_arguments.IsInstantiated()) {
    // There are no type references to type parameters so we can just take it.
    instructions += Constant(type_arguments);
  } else {
    // The [type_arguments] vector contains a type reference to a type
    // parameter we need to resolve it.
    if (type_arguments.CanShareInstantiatorTypeArguments(
            *active_class_.klass)) {
      // If the instantiator type arguments are just passed on, we don't need to
      // resolve the type parameters.
      //
      // This is for example the case here:
      //     class Foo<T> {
      //       newList() => new List<T>();
      //     }
      // We just use the type argument vector from the [Foo] object and pass it
      // directly to the `new List<T>()` factory constructor.
      instructions += LoadInstantiatorTypeArguments();
    } else if (type_arguments.CanShareFunctionTypeArguments(
                   parsed_function_->function())) {
      instructions += LoadFunctionTypeArguments();
    } else {
      // Otherwise we need to resolve [TypeParameterType]s in the type
      // expression based on the current instantiator type argument vector.
      if (!type_arguments.IsInstantiated(kCurrentClass)) {
        instructions += LoadInstantiatorTypeArguments();
      } else {
        instructions += NullConstant();
      }
      if (!type_arguments.IsInstantiated(kFunctions)) {
        instructions += LoadFunctionTypeArguments();
      } else {
        instructions += NullConstant();
      }
      instructions += InstantiateTypeArguments(type_arguments);
    }
  }
  return instructions;
}

Fragment FlowGraphBuilder::CatchBlockEntry(const Array& handler_types,
                                           intptr_t handler_index,
                                           bool needs_stacktrace,
                                           bool is_synthesized) {
  LocalVariable* exception_var = CurrentException();
  LocalVariable* stacktrace_var = CurrentStackTrace();
  LocalVariable* raw_exception_var = CurrentRawException();
  LocalVariable* raw_stacktrace_var = CurrentRawStackTrace();

  CatchBlockEntryInstr* entry = new (Z) CatchBlockEntryInstr(
      is_synthesized,  // whether catch block was synthesized by FE compiler
      AllocateBlockId(), CurrentTryIndex(), graph_entry_, handler_types,
      handler_index, needs_stacktrace, GetNextDeoptId(), exception_var,
      stacktrace_var, raw_exception_var, raw_stacktrace_var);
  graph_entry_->AddCatchEntry(entry);

  Fragment instructions(entry);

  // Auxiliary variables introduced by the try catch can be captured if we are
  // inside a function with yield/resume points. In this case we first need
  // to restore the context to match the context at entry into the closure.
  const bool should_restore_closure_context =
      CurrentException()->is_captured() || CurrentCatchContext()->is_captured();
  LocalVariable* context_variable = parsed_function_->current_context_var();
  if (should_restore_closure_context) {
    ASSERT(parsed_function_->function().IsClosureFunction());

    LocalVariable* closure_parameter = parsed_function_->ParameterVariable(0);
    ASSERT(!closure_parameter->is_captured());
    instructions += LoadLocal(closure_parameter);
    instructions += LoadNativeField(Slot::Closure_context());
    instructions += StoreLocal(TokenPosition::kNoSource, context_variable);
    instructions += Drop();
  }

  if (exception_var->is_captured()) {
    instructions += LoadLocal(context_variable);
    instructions += LoadLocal(raw_exception_var);
    instructions += StoreInstanceField(
        TokenPosition::kNoSource,
        Slot::GetContextVariableSlotFor(thread_, *exception_var));
  }
  if (stacktrace_var->is_captured()) {
    instructions += LoadLocal(context_variable);
    instructions += LoadLocal(raw_stacktrace_var);
    instructions += StoreInstanceField(
        TokenPosition::kNoSource,
        Slot::GetContextVariableSlotFor(thread_, *stacktrace_var));
  }

  // :saved_try_context_var can be captured in the context of
  // of the closure, in this case CatchBlockEntryInstr restores
  // :current_context_var to point to closure context in the
  // same way as normal function prologue does.
  // Update current context depth to reflect that.
  const intptr_t saved_context_depth = context_depth_;
  ASSERT(!CurrentCatchContext()->is_captured() ||
         CurrentCatchContext()->owner()->context_level() == 0);
  context_depth_ = 0;
  instructions += LoadLocal(CurrentCatchContext());
  instructions += StoreLocal(TokenPosition::kNoSource,
                             parsed_function_->current_context_var());
  instructions += Drop();
  context_depth_ = saved_context_depth;

  return instructions;
}

Fragment FlowGraphBuilder::TryCatch(int try_handler_index) {
  // The body of the try needs to have it's own block in order to get a new try
  // index.
  //
  // => We therefore create a block for the body (fresh try index) and another
  //    join block (with current try index).
  Fragment body;
  JoinEntryInstr* entry = new (Z)
      JoinEntryInstr(AllocateBlockId(), try_handler_index, GetNextDeoptId());
  body += LoadLocal(parsed_function_->current_context_var());
  body += StoreLocal(TokenPosition::kNoSource, CurrentCatchContext());
  body += Drop();
  body += Goto(entry);
  return Fragment(body.entry, entry);
}

Fragment FlowGraphBuilder::CheckStackOverflowInPrologue(
    TokenPosition position) {
  ASSERT(loop_depth_ == 0);
  return BaseFlowGraphBuilder::CheckStackOverflowInPrologue(position);
}

Fragment FlowGraphBuilder::CloneContext(
    const ZoneGrowableArray<const Slot*>& context_slots) {
  LocalVariable* context_variable = parsed_function_->current_context_var();

  Fragment instructions = LoadLocal(context_variable);

  CloneContextInstr* clone_instruction = new (Z) CloneContextInstr(
      TokenPosition::kNoSource, Pop(), context_slots, GetNextDeoptId());
  instructions <<= clone_instruction;
  Push(clone_instruction);

  instructions += StoreLocal(TokenPosition::kNoSource, context_variable);
  instructions += Drop();
  return instructions;
}

Fragment FlowGraphBuilder::InstanceCall(
    TokenPosition position,
    const String& name,
    Token::Kind kind,
    intptr_t type_args_len,
    intptr_t argument_count,
    const Array& argument_names,
    intptr_t checked_argument_count,
    const Function& interface_target,
    const InferredTypeMetadata* result_type,
    bool use_unchecked_entry,
    const CallSiteAttributesMetadata* call_site_attrs) {
  const intptr_t total_count = argument_count + (type_args_len > 0 ? 1 : 0);
  ArgumentArray arguments = GetArguments(total_count);
  InstanceCallInstr* call = new (Z)
      InstanceCallInstr(position, name, kind, arguments, type_args_len,
                        argument_names, checked_argument_count, ic_data_array_,
                        GetNextDeoptId(), interface_target);
  if ((result_type != NULL) && !result_type->IsTrivial()) {
    call->SetResultType(Z, result_type->ToCompileType(Z));
  }
  if (use_unchecked_entry) {
    call->set_entry_kind(Code::EntryKind::kUnchecked);
  }
  if (call_site_attrs != nullptr && call_site_attrs->receiver_type != nullptr &&
      call_site_attrs->receiver_type->IsInstantiated()) {
    call->set_receivers_static_type(call_site_attrs->receiver_type);
  } else if (!interface_target.IsNull()) {
    const Class& owner = Class::Handle(Z, interface_target.Owner());
    const AbstractType& type =
        AbstractType::ZoneHandle(Z, owner.DeclarationType());
    call->set_receivers_static_type(&type);
  }
  Push(call);
  return Fragment(call);
}

Fragment FlowGraphBuilder::FfiCall(
    const Function& signature,
    const ZoneGrowableArray<Representation>& arg_reps,
    const ZoneGrowableArray<Location>& arg_locs,
    const ZoneGrowableArray<HostLocation>* arg_host_locs) {
  Fragment body;

  FfiCallInstr* const call = new (Z) FfiCallInstr(
      Z, GetNextDeoptId(), signature, arg_reps, arg_locs, arg_host_locs);

  for (intptr_t i = call->InputCount() - 1; i >= 0; --i) {
    call->SetInputAt(i, Pop());
  }

  Push(call);
  body <<= call;

  return body;
}

Fragment FlowGraphBuilder::RethrowException(TokenPosition position,
                                            int catch_try_index) {
  Fragment instructions;
  instructions += Drop();
  instructions += Drop();
  instructions += Fragment(new (Z) ReThrowInstr(position, catch_try_index,
                                                GetNextDeoptId()))
                      .closed();
  // Use it's side effect of leaving a constant on the stack (does not change
  // the graph).
  NullConstant();

  pending_argument_count_ -= 2;

  return instructions;
}

Fragment FlowGraphBuilder::LoadLocal(LocalVariable* variable) {
  if (variable->is_captured()) {
    Fragment instructions;
    instructions += LoadContextAt(variable->owner()->context_level());
    instructions +=
        LoadNativeField(Slot::GetContextVariableSlotFor(thread_, *variable));
    return instructions;
  } else {
    return BaseFlowGraphBuilder::LoadLocal(variable);
  }
}

Fragment FlowGraphBuilder::InitStaticField(const Field& field) {
  InitStaticFieldInstr* init = new (Z)
      InitStaticFieldInstr(Pop(), MayCloneField(field), GetNextDeoptId());
  return Fragment(init);
}

Fragment FlowGraphBuilder::NativeCall(const String* name,
                                      const Function* function) {
  InlineBailout("kernel::FlowGraphBuilder::NativeCall");
  const intptr_t num_args =
      function->NumParameters() + (function->IsGeneric() ? 1 : 0);
  ArgumentArray arguments = GetArguments(num_args);
  NativeCallInstr* call =
      new (Z) NativeCallInstr(name, function, FLAG_link_natives_lazily,
                              function->end_token_pos(), arguments);
  Push(call);
  return Fragment(call);
}

Fragment FlowGraphBuilder::Return(TokenPosition position,
                                  bool omit_result_type_check /* = false */) {
  Fragment instructions;
  const Function& function = parsed_function_->function();

  // Emit a type check of the return type in checked mode for all functions
  // and in strong mode for native functions.
  if (!omit_result_type_check && function.is_native()) {
    const AbstractType& return_type =
        AbstractType::Handle(Z, function.result_type());
    instructions += CheckAssignable(return_type, Symbols::FunctionResult());
  }

  if (NeedsDebugStepCheck(function, position)) {
    instructions += DebugStepCheck(position);
  }

  if (FLAG_causal_async_stacks &&
      (function.IsAsyncClosure() || function.IsAsyncGenClosure())) {
    // We are returning from an asynchronous closure. Before we do that, be
    // sure to clear the thread's asynchronous stack trace.
    const Function& target = Function::ZoneHandle(
        Z, I->object_store()->async_clear_thread_stack_trace());
    ASSERT(!target.IsNull());
    instructions += StaticCall(TokenPosition::kNoSource, target,
                               /* argument_count = */ 0, ICData::kStatic);
    instructions += Drop();
  }

  instructions += BaseFlowGraphBuilder::Return(position);

  return instructions;
}

Fragment FlowGraphBuilder::StaticCall(TokenPosition position,
                                      const Function& target,
                                      intptr_t argument_count,
                                      ICData::RebindRule rebind_rule) {
  return StaticCall(position, target, argument_count, Array::null_array(),
                    rebind_rule);
}

void FlowGraphBuilder::SetResultTypeForStaticCall(
    StaticCallInstr* call,
    const Function& target,
    intptr_t argument_count,
    const InferredTypeMetadata* result_type) {
  if (call->InitResultType(Z)) {
    ASSERT((result_type == NULL) || (result_type->cid == kDynamicCid) ||
           (result_type->cid == call->result_cid()));
    return;
  }
  if ((result_type != NULL) && !result_type->IsTrivial()) {
    call->SetResultType(Z, result_type->ToCompileType(Z));
  }
}

Fragment FlowGraphBuilder::StaticCall(TokenPosition position,
                                      const Function& target,
                                      intptr_t argument_count,
                                      const Array& argument_names,
                                      ICData::RebindRule rebind_rule,
                                      const InferredTypeMetadata* result_type,
                                      intptr_t type_args_count,
                                      bool use_unchecked_entry) {
  const intptr_t total_count = argument_count + (type_args_count > 0 ? 1 : 0);
  ArgumentArray arguments = GetArguments(total_count);
  StaticCallInstr* call = new (Z)
      StaticCallInstr(position, target, type_args_count, argument_names,
                      arguments, ic_data_array_, GetNextDeoptId(), rebind_rule);
  SetResultTypeForStaticCall(call, target, argument_count, result_type);
  if (use_unchecked_entry) {
    call->set_entry_kind(Code::EntryKind::kUnchecked);
  }
  Push(call);
  return Fragment(call);
}

Fragment FlowGraphBuilder::StringInterpolateSingle(TokenPosition position) {
  const int kTypeArgsLen = 0;
  const int kNumberOfArguments = 1;
  const Array& kNoArgumentNames = Object::null_array();
  const Class& cls =
      Class::Handle(Library::LookupCoreClass(Symbols::StringBase()));
  ASSERT(!cls.IsNull());
  const Function& function = Function::ZoneHandle(
      Z, Resolver::ResolveStatic(
             cls, Library::PrivateCoreLibName(Symbols::InterpolateSingle()),
             kTypeArgsLen, kNumberOfArguments, kNoArgumentNames));
  Fragment instructions;
  instructions += PushArgument();
  instructions +=
      StaticCall(position, function, /* argument_count = */ 1, ICData::kStatic);
  return instructions;
}

Fragment FlowGraphBuilder::ThrowTypeError() {
  const Class& klass =
      Class::ZoneHandle(Z, Library::LookupCoreClass(Symbols::TypeError()));
  ASSERT(!klass.IsNull());
  GrowableHandlePtrArray<const String> pieces(Z, 3);
  pieces.Add(Symbols::TypeError());
  pieces.Add(Symbols::Dot());
  pieces.Add(H.DartSymbolObfuscate("_create"));

  const Function& constructor = Function::ZoneHandle(
      Z, klass.LookupConstructorAllowPrivate(
             String::ZoneHandle(Z, Symbols::FromConcatAll(thread_, pieces))));
  ASSERT(!constructor.IsNull());

  const String& url = H.DartString(
      parsed_function_->function().ToLibNamePrefixedQualifiedCString(),
      Heap::kOld);

  Fragment instructions;

  // Create instance of _FallThroughError
  instructions += AllocateObject(TokenPosition::kNoSource, klass, 0);
  LocalVariable* instance = MakeTemporary();

  // Call _TypeError._create constructor.
  instructions += LoadLocal(instance);
  instructions += PushArgument();  // this

  instructions += Constant(url);
  instructions += PushArgument();  // url

  instructions += NullConstant();
  instructions += PushArgument();  // line

  instructions += IntConstant(0);
  instructions += PushArgument();  // column

  instructions += Constant(H.DartSymbolPlain("Malformed type."));
  instructions += PushArgument();  // message

  instructions += StaticCall(TokenPosition::kNoSource, constructor,
                             /* argument_count = */ 5, ICData::kStatic);
  instructions += Drop();

  // Throw the exception
  instructions += PushArgument();
  instructions += ThrowException(TokenPosition::kNoSource);

  return instructions;
}

Fragment FlowGraphBuilder::ThrowNoSuchMethodError() {
  const Class& klass = Class::ZoneHandle(
      Z, Library::LookupCoreClass(Symbols::NoSuchMethodError()));
  ASSERT(!klass.IsNull());
  const Function& throw_function = Function::ZoneHandle(
      Z, klass.LookupStaticFunctionAllowPrivate(Symbols::ThrowNew()));
  ASSERT(!throw_function.IsNull());

  Fragment instructions;

  // Call NoSuchMethodError._throwNew static function.
  instructions += NullConstant();
  instructions += PushArgument();  // receiver

  instructions += Constant(H.DartString("<unknown>", Heap::kOld));
  instructions += PushArgument();  // memberName

  instructions += IntConstant(-1);
  instructions += PushArgument();  // invocation_type

  instructions += NullConstant();
  instructions += PushArgument();  // type arguments

  instructions += NullConstant();
  instructions += PushArgument();  // arguments

  instructions += NullConstant();
  instructions += PushArgument();  // argumentNames

  instructions += StaticCall(TokenPosition::kNoSource, throw_function,
                             /* argument_count = */ 6, ICData::kStatic);
  // Leave "result" on the stack since callers expect it to be there (even
  // though the function will result in an exception).

  return instructions;
}

LocalVariable* FlowGraphBuilder::LookupVariable(intptr_t kernel_offset) {
  LocalVariable* local = scopes_->locals.Lookup(kernel_offset);
  ASSERT(local != NULL);
  return local;
}

FlowGraph* FlowGraphBuilder::BuildGraph() {
  const Function& function = parsed_function_->function();

#ifdef DEBUG
  // If we attached the native name to the function after it's creation (namely
  // after reading the constant table from the kernel blob), we must have done
  // so before building flow graph for the functions (since FGB depends needs
  // the native name to be there).
  const Script& script = Script::Handle(Z, function.script());
  const KernelProgramInfo& info =
      KernelProgramInfo::Handle(script.kernel_program_info());
  ASSERT(info.IsNull() ||
         info.potential_natives() == GrowableObjectArray::null());
#endif

  auto& kernel_data = ExternalTypedData::Handle(Z);
  intptr_t kernel_data_program_offset = 0;
  if (!function.is_declared_in_bytecode()) {
    kernel_data = function.KernelData();
    kernel_data_program_offset = function.KernelDataProgramOffset();
  }

  // TODO(alexmarkov): refactor this - StreamingFlowGraphBuilder should not be
  //  used for bytecode functions.
  StreamingFlowGraphBuilder streaming_flow_graph_builder(
      this, kernel_data, kernel_data_program_offset, record_yield_positions_);
  return streaming_flow_graph_builder.BuildGraph();
}

Fragment FlowGraphBuilder::NativeFunctionBody(const Function& function,
                                              LocalVariable* first_parameter) {
  ASSERT(function.is_native());
  ASSERT(!IsRecognizedMethodForFlowGraph(function));

  Fragment body;
  String& name = String::ZoneHandle(Z, function.native_name());
  if (function.IsGeneric()) {
    body += LoadLocal(parsed_function_->RawTypeArgumentsVariable());
    body += PushArgument();
  }
  for (intptr_t i = 0; i < function.NumParameters(); ++i) {
    body += LoadLocal(parsed_function_->RawParameterVariable(i));
    body += PushArgument();
  }
  body += NativeCall(&name, &function);
  // We typecheck results of native calls for type safety.
  body +=
      Return(TokenPosition::kNoSource, /* omit_result_type_check = */ false);
  return body;
}

bool FlowGraphBuilder::IsRecognizedMethodForFlowGraph(
    const Function& function) {
  const MethodRecognizer::Kind kind = MethodRecognizer::RecognizeKind(function);

  switch (kind) {
    case MethodRecognizer::kTypedData_ByteDataView_factory:
    case MethodRecognizer::kTypedData_Int8ArrayView_factory:
    case MethodRecognizer::kTypedData_Uint8ArrayView_factory:
    case MethodRecognizer::kTypedData_Uint8ClampedArrayView_factory:
    case MethodRecognizer::kTypedData_Int16ArrayView_factory:
    case MethodRecognizer::kTypedData_Uint16ArrayView_factory:
    case MethodRecognizer::kTypedData_Int32ArrayView_factory:
    case MethodRecognizer::kTypedData_Uint32ArrayView_factory:
    case MethodRecognizer::kTypedData_Int64ArrayView_factory:
    case MethodRecognizer::kTypedData_Uint64ArrayView_factory:
    case MethodRecognizer::kTypedData_Float32ArrayView_factory:
    case MethodRecognizer::kTypedData_Float64ArrayView_factory:
    case MethodRecognizer::kTypedData_Float32x4ArrayView_factory:
    case MethodRecognizer::kTypedData_Int32x4ArrayView_factory:
    case MethodRecognizer::kTypedData_Float64x2ArrayView_factory:
    case MethodRecognizer::kFfiLoadInt8:
    case MethodRecognizer::kFfiLoadInt16:
    case MethodRecognizer::kFfiLoadInt32:
    case MethodRecognizer::kFfiLoadInt64:
    case MethodRecognizer::kFfiLoadUint8:
    case MethodRecognizer::kFfiLoadUint16:
    case MethodRecognizer::kFfiLoadUint32:
    case MethodRecognizer::kFfiLoadUint64:
    case MethodRecognizer::kFfiLoadIntPtr:
    case MethodRecognizer::kFfiLoadFloat:
    case MethodRecognizer::kFfiLoadDouble:
    case MethodRecognizer::kFfiLoadPointer:
    case MethodRecognizer::kFfiStoreInt8:
    case MethodRecognizer::kFfiStoreInt16:
    case MethodRecognizer::kFfiStoreInt32:
    case MethodRecognizer::kFfiStoreInt64:
    case MethodRecognizer::kFfiStoreUint8:
    case MethodRecognizer::kFfiStoreUint16:
    case MethodRecognizer::kFfiStoreUint32:
    case MethodRecognizer::kFfiStoreUint64:
    case MethodRecognizer::kFfiStoreIntPtr:
    case MethodRecognizer::kFfiStoreFloat:
    case MethodRecognizer::kFfiStoreDouble:
    case MethodRecognizer::kFfiStorePointer:
    case MethodRecognizer::kFfiFromAddress:
    case MethodRecognizer::kFfiGetAddress:
    // This list must be kept in sync with BytecodeReaderHelper::NativeEntry in
    // runtime/vm/compiler/frontend/bytecode_reader.cc and implemented in the
    // bytecode interpreter in runtime/vm/interpreter.cc. Alternatively, these
    // methods must work in their original form (a Dart body or native entry) in
    // the bytecode interpreter.
    case MethodRecognizer::kObjectEquals:
    case MethodRecognizer::kStringBaseLength:
    case MethodRecognizer::kStringBaseIsEmpty:
    case MethodRecognizer::kGrowableArrayLength:
    case MethodRecognizer::kObjectArrayLength:
    case MethodRecognizer::kImmutableArrayLength:
    case MethodRecognizer::kTypedListLength:
    case MethodRecognizer::kTypedListViewLength:
    case MethodRecognizer::kByteDataViewLength:
    case MethodRecognizer::kByteDataViewOffsetInBytes:
    case MethodRecognizer::kTypedDataViewOffsetInBytes:
    case MethodRecognizer::kByteDataViewTypedData:
    case MethodRecognizer::kTypedDataViewTypedData:
    case MethodRecognizer::kClassIDgetID:
    case MethodRecognizer::kGrowableArrayCapacity:
    case MethodRecognizer::kListFactory:
    case MethodRecognizer::kObjectArrayAllocate:
    case MethodRecognizer::kLinkedHashMap_getIndex:
    case MethodRecognizer::kLinkedHashMap_setIndex:
    case MethodRecognizer::kLinkedHashMap_getData:
    case MethodRecognizer::kLinkedHashMap_setData:
    case MethodRecognizer::kLinkedHashMap_getHashMask:
    case MethodRecognizer::kLinkedHashMap_setHashMask:
    case MethodRecognizer::kLinkedHashMap_getUsedData:
    case MethodRecognizer::kLinkedHashMap_setUsedData:
    case MethodRecognizer::kLinkedHashMap_getDeletedKeys:
    case MethodRecognizer::kLinkedHashMap_setDeletedKeys:
    case MethodRecognizer::kFfiAbi:
      return true;
    case MethodRecognizer::kAsyncStackTraceHelper:
      return !FLAG_causal_async_stacks;
    default:
      return false;
  }
}

FlowGraph* FlowGraphBuilder::BuildGraphOfRecognizedMethod(
    const Function& function) {
  ASSERT(IsRecognizedMethodForFlowGraph(function));

  graph_entry_ =
      new (Z) GraphEntryInstr(*parsed_function_, Compiler::kNoOSRDeoptId);

  auto normal_entry = BuildFunctionEntry(graph_entry_);
  graph_entry_->set_normal_entry(normal_entry);

  PrologueInfo prologue_info(-1, -1);
  BlockEntryInstr* instruction_cursor =
      BuildPrologue(normal_entry, &prologue_info);

  Fragment body(instruction_cursor);
  body += CheckStackOverflowInPrologue(function.token_pos());

  const MethodRecognizer::Kind kind = MethodRecognizer::RecognizeKind(function);
  switch (kind) {
    case MethodRecognizer::kTypedData_ByteDataView_factory:
      body += BuildTypedDataViewFactoryConstructor(function, kByteDataViewCid);
      break;
    case MethodRecognizer::kTypedData_Int8ArrayView_factory:
      body += BuildTypedDataViewFactoryConstructor(function,
                                                   kTypedDataInt8ArrayViewCid);
      break;
    case MethodRecognizer::kTypedData_Uint8ArrayView_factory:
      body += BuildTypedDataViewFactoryConstructor(function,
                                                   kTypedDataUint8ArrayViewCid);
      break;
    case MethodRecognizer::kTypedData_Uint8ClampedArrayView_factory:
      body += BuildTypedDataViewFactoryConstructor(
          function, kTypedDataUint8ClampedArrayViewCid);
      break;
    case MethodRecognizer::kTypedData_Int16ArrayView_factory:
      body += BuildTypedDataViewFactoryConstructor(function,
                                                   kTypedDataInt16ArrayViewCid);
      break;
    case MethodRecognizer::kTypedData_Uint16ArrayView_factory:
      body += BuildTypedDataViewFactoryConstructor(
          function, kTypedDataUint16ArrayViewCid);
      break;
    case MethodRecognizer::kTypedData_Int32ArrayView_factory:
      body += BuildTypedDataViewFactoryConstructor(function,
                                                   kTypedDataInt32ArrayViewCid);
      break;
    case MethodRecognizer::kTypedData_Uint32ArrayView_factory:
      body += BuildTypedDataViewFactoryConstructor(
          function, kTypedDataUint32ArrayViewCid);
      break;
    case MethodRecognizer::kTypedData_Int64ArrayView_factory:
      body += BuildTypedDataViewFactoryConstructor(function,
                                                   kTypedDataInt64ArrayViewCid);
      break;
    case MethodRecognizer::kTypedData_Uint64ArrayView_factory:
      body += BuildTypedDataViewFactoryConstructor(
          function, kTypedDataUint64ArrayViewCid);
      break;
    case MethodRecognizer::kTypedData_Float32ArrayView_factory:
      body += BuildTypedDataViewFactoryConstructor(
          function, kTypedDataFloat32ArrayViewCid);
      break;
    case MethodRecognizer::kTypedData_Float64ArrayView_factory:
      body += BuildTypedDataViewFactoryConstructor(
          function, kTypedDataFloat64ArrayViewCid);
      break;
    case MethodRecognizer::kTypedData_Float32x4ArrayView_factory:
      body += BuildTypedDataViewFactoryConstructor(
          function, kTypedDataFloat32x4ArrayViewCid);
      break;
    case MethodRecognizer::kTypedData_Int32x4ArrayView_factory:
      body += BuildTypedDataViewFactoryConstructor(
          function, kTypedDataInt32x4ArrayViewCid);
      break;
    case MethodRecognizer::kTypedData_Float64x2ArrayView_factory:
      body += BuildTypedDataViewFactoryConstructor(
          function, kTypedDataFloat64x2ArrayViewCid);
      break;
    case MethodRecognizer::kObjectEquals:
      ASSERT(function.NumParameters() == 2);
      body += LoadLocal(parsed_function_->RawParameterVariable(0));
      body += LoadLocal(parsed_function_->RawParameterVariable(1));
      body += StrictCompare(Token::kEQ_STRICT);
      break;
    case MethodRecognizer::kStringBaseLength:
    case MethodRecognizer::kStringBaseIsEmpty:
      ASSERT(function.NumParameters() == 1);
      body += LoadLocal(parsed_function_->RawParameterVariable(0));
      body += LoadNativeField(Slot::String_length());
      if (kind == MethodRecognizer::kStringBaseIsEmpty) {
        body += IntConstant(0);
        body += StrictCompare(Token::kEQ_STRICT);
      }
      break;
    case MethodRecognizer::kGrowableArrayLength:
      ASSERT(function.NumParameters() == 1);
      body += LoadLocal(parsed_function_->RawParameterVariable(0));
      body += LoadNativeField(Slot::GrowableObjectArray_length());
      break;
    case MethodRecognizer::kObjectArrayLength:
    case MethodRecognizer::kImmutableArrayLength:
      ASSERT(function.NumParameters() == 1);
      body += LoadLocal(parsed_function_->RawParameterVariable(0));
      body += LoadNativeField(Slot::Array_length());
      break;
    case MethodRecognizer::kTypedListLength:
    case MethodRecognizer::kTypedListViewLength:
    case MethodRecognizer::kByteDataViewLength:
      ASSERT(function.NumParameters() == 1);
      body += LoadLocal(parsed_function_->RawParameterVariable(0));
      body += LoadNativeField(Slot::TypedDataBase_length());
      break;
    case MethodRecognizer::kByteDataViewOffsetInBytes:
    case MethodRecognizer::kTypedDataViewOffsetInBytes:
      ASSERT(function.NumParameters() == 1);
      body += LoadLocal(parsed_function_->RawParameterVariable(0));
      body += LoadNativeField(Slot::TypedDataView_offset_in_bytes());
      break;
    case MethodRecognizer::kByteDataViewTypedData:
    case MethodRecognizer::kTypedDataViewTypedData:
      ASSERT(function.NumParameters() == 1);
      body += LoadLocal(parsed_function_->RawParameterVariable(0));
      body += LoadNativeField(Slot::TypedDataView_data());
      break;
    case MethodRecognizer::kClassIDgetID:
      ASSERT(function.NumParameters() == 1);
      body += LoadLocal(parsed_function_->RawParameterVariable(0));
      body += LoadClassId();
      break;
    case MethodRecognizer::kGrowableArrayCapacity:
      ASSERT(function.NumParameters() == 1);
      body += LoadLocal(parsed_function_->RawParameterVariable(0));
      body += LoadNativeField(Slot::GrowableObjectArray_data());
      body += LoadNativeField(Slot::Array_length());
      break;
    case MethodRecognizer::kListFactory: {
      ASSERT(function.IsFactory() && (function.NumParameters() == 2) &&
             function.HasOptionalParameters());
      // factory List<E>([int length]) {
      //   return (:arg_desc.positional_count == 2) ? new _List<E>(length)
      //                                            : new _GrowableList<E>(0);
      // }
      const Library& core_lib = Library::Handle(Z, Library::CoreLibrary());

      TargetEntryInstr *allocate_non_growable, *allocate_growable;

      body += LoadArgDescriptor();
      body += LoadNativeField(Slot::ArgumentsDescriptor_positional_count());
      body += IntConstant(2);
      body += BranchIfStrictEqual(&allocate_non_growable, &allocate_growable);

      JoinEntryInstr* join = BuildJoinEntry();

      {
        const Class& cls = Class::Handle(
            Z, core_lib.LookupClass(
                   Library::PrivateCoreLibName(Symbols::_List())));
        ASSERT(!cls.IsNull());
        const Function& func = Function::ZoneHandle(
            Z, cls.LookupFactoryAllowPrivate(Symbols::_ListFactory()));
        ASSERT(!func.IsNull());

        Fragment allocate(allocate_non_growable);
        allocate += LoadLocal(parsed_function_->RawParameterVariable(0));
        allocate += PushArgument();
        allocate += LoadLocal(parsed_function_->RawParameterVariable(1));
        allocate += PushArgument();
        allocate +=
            StaticCall(TokenPosition::kNoSource, func, 2, ICData::kStatic);
        allocate += StoreLocal(TokenPosition::kNoSource,
                               parsed_function_->expression_temp_var());
        allocate += Drop();
        allocate += Goto(join);
      }

      {
        const Class& cls = Class::Handle(
            Z, core_lib.LookupClass(
                   Library::PrivateCoreLibName(Symbols::_GrowableList())));
        ASSERT(!cls.IsNull());
        const Function& func = Function::ZoneHandle(
            Z, cls.LookupFactoryAllowPrivate(Symbols::_GrowableListFactory()));
        ASSERT(!func.IsNull());

        Fragment allocate(allocate_growable);
        allocate += LoadLocal(parsed_function_->RawParameterVariable(0));
        allocate += PushArgument();
        allocate += IntConstant(0);
        allocate += PushArgument();
        allocate +=
            StaticCall(TokenPosition::kNoSource, func, 2, ICData::kStatic);
        allocate += StoreLocal(TokenPosition::kNoSource,
                               parsed_function_->expression_temp_var());
        allocate += Drop();
        allocate += Goto(join);
      }

      body = Fragment(body.entry, join);
      body += LoadLocal(parsed_function_->expression_temp_var());
      break;
    }
    case MethodRecognizer::kObjectArrayAllocate:
      ASSERT(function.IsFactory() && (function.NumParameters() == 2));
      body += LoadLocal(parsed_function_->RawParameterVariable(0));
      body += LoadLocal(parsed_function_->RawParameterVariable(1));
      body += CreateArray();
      break;
    case MethodRecognizer::kLinkedHashMap_getIndex:
      ASSERT(function.NumParameters() == 1);
      body += LoadLocal(parsed_function_->RawParameterVariable(0));
      body += LoadNativeField(Slot::LinkedHashMap_index());
      break;
    case MethodRecognizer::kLinkedHashMap_setIndex:
      ASSERT(function.NumParameters() == 2);
      body += LoadLocal(parsed_function_->RawParameterVariable(0));
      body += LoadLocal(parsed_function_->RawParameterVariable(1));
      body += StoreInstanceField(TokenPosition::kNoSource,
                                 Slot::LinkedHashMap_index());
      body += NullConstant();
      break;
    case MethodRecognizer::kLinkedHashMap_getData:
      ASSERT(function.NumParameters() == 1);
      body += LoadLocal(parsed_function_->RawParameterVariable(0));
      body += LoadNativeField(Slot::LinkedHashMap_data());
      break;
    case MethodRecognizer::kLinkedHashMap_setData:
      ASSERT(function.NumParameters() == 2);
      body += LoadLocal(parsed_function_->RawParameterVariable(0));
      body += LoadLocal(parsed_function_->RawParameterVariable(1));
      body += StoreInstanceField(TokenPosition::kNoSource,
                                 Slot::LinkedHashMap_data());
      body += NullConstant();
      break;
    case MethodRecognizer::kLinkedHashMap_getHashMask:
      ASSERT(function.NumParameters() == 1);
      body += LoadLocal(parsed_function_->RawParameterVariable(0));
      body += LoadNativeField(Slot::LinkedHashMap_hash_mask());
      break;
    case MethodRecognizer::kLinkedHashMap_setHashMask:
      ASSERT(function.NumParameters() == 2);
      body += LoadLocal(parsed_function_->RawParameterVariable(0));
      body += LoadLocal(parsed_function_->RawParameterVariable(1));
      body += StoreInstanceField(
          TokenPosition::kNoSource, Slot::LinkedHashMap_hash_mask(),
          StoreInstanceFieldInstr::Kind::kOther, kNoStoreBarrier);
      body += NullConstant();
      break;
    case MethodRecognizer::kLinkedHashMap_getUsedData:
      ASSERT(function.NumParameters() == 1);
      body += LoadLocal(parsed_function_->RawParameterVariable(0));
      body += LoadNativeField(Slot::LinkedHashMap_used_data());
      break;
    case MethodRecognizer::kLinkedHashMap_setUsedData:
      ASSERT(function.NumParameters() == 2);
      body += LoadLocal(parsed_function_->RawParameterVariable(0));
      body += LoadLocal(parsed_function_->RawParameterVariable(1));
      body += StoreInstanceField(
          TokenPosition::kNoSource, Slot::LinkedHashMap_used_data(),
          StoreInstanceFieldInstr::Kind::kOther, kNoStoreBarrier);
      body += NullConstant();
      break;
    case MethodRecognizer::kLinkedHashMap_getDeletedKeys:
      ASSERT(function.NumParameters() == 1);
      body += LoadLocal(parsed_function_->RawParameterVariable(0));
      body += LoadNativeField(Slot::LinkedHashMap_deleted_keys());
      break;
    case MethodRecognizer::kLinkedHashMap_setDeletedKeys:
      ASSERT(function.NumParameters() == 2);
      body += LoadLocal(parsed_function_->RawParameterVariable(0));
      body += LoadLocal(parsed_function_->RawParameterVariable(1));
      body += StoreInstanceField(
          TokenPosition::kNoSource, Slot::LinkedHashMap_deleted_keys(),
          StoreInstanceFieldInstr::Kind::kOther, kNoStoreBarrier);
      body += NullConstant();
      break;
    case MethodRecognizer::kAsyncStackTraceHelper:
      ASSERT(!FLAG_causal_async_stacks);
      body += NullConstant();
      break;
    case MethodRecognizer::kFfiAbi:
      ASSERT(function.NumParameters() == 0);
      body += IntConstant(static_cast<int64_t>(compiler::ffi::TargetAbi()));
      break;
    case MethodRecognizer::kFfiLoadInt8:
    case MethodRecognizer::kFfiLoadInt16:
    case MethodRecognizer::kFfiLoadInt32:
    case MethodRecognizer::kFfiLoadInt64:
    case MethodRecognizer::kFfiLoadUint8:
    case MethodRecognizer::kFfiLoadUint16:
    case MethodRecognizer::kFfiLoadUint32:
    case MethodRecognizer::kFfiLoadUint64:
    case MethodRecognizer::kFfiLoadIntPtr:
    case MethodRecognizer::kFfiLoadFloat:
    case MethodRecognizer::kFfiLoadDouble:
    case MethodRecognizer::kFfiLoadPointer: {
      const classid_t ffi_type_arg_cid =
          compiler::ffi::RecognizedMethodTypeArgCid(kind);
      const classid_t typed_data_cid =
          compiler::ffi::ElementTypedDataCid(ffi_type_arg_cid);
      const Representation representation =
          compiler::ffi::TypeRepresentation(ffi_type_arg_cid);

      // Check Dart signature type.
      const auto& receiver_type =
          AbstractType::Handle(function.ParameterTypeAt(0));
      const auto& type_args = TypeArguments::Handle(receiver_type.arguments());
      const auto& type_arg = AbstractType::Handle(type_args.TypeAt(0));
      ASSERT(ffi_type_arg_cid == type_arg.type_class_id());

      ASSERT(function.NumParameters() == 2);
      body += LoadLocal(parsed_function_->RawParameterVariable(0));  // Pointer.
      body += CheckNullOptimized(TokenPosition::kNoSource,
                                 String::ZoneHandle(Z, function.name()));
      body += LoadNativeField(Slot::Pointer_c_memory_address());
      body += UnboxTruncate(kUnboxedFfiIntPtr);
      // We do Pointer.address + index * sizeOf<T> manually because LoadIndexed
      // does not support Mint index arguments.
      body += LoadLocal(parsed_function_->RawParameterVariable(1));  // Index.
      body += CheckNullOptimized(TokenPosition::kNoSource,
                                 String::ZoneHandle(Z, function.name()));
      body += UnboxTruncate(kUnboxedFfiIntPtr);
      body += IntConstant(compiler::ffi::ElementSizeInBytes(ffi_type_arg_cid));
      body += UnboxTruncate(kUnboxedIntPtr);
      // TODO(38831): Implement Shift for Uint32, and use that instead.
      body +=
          BinaryIntegerOp(Token::kMUL, kUnboxedFfiIntPtr, /* truncate= */ true);
      body +=
          BinaryIntegerOp(Token::kADD, kUnboxedFfiIntPtr, /* truncate= */ true);
      body += ConvertIntptrToUntagged();
      body += IntConstant(0);
      body += LoadIndexedTypedData(typed_data_cid);
      if (kind == MethodRecognizer::kFfiLoadFloat ||
          kind == MethodRecognizer::kFfiLoadDouble) {
        if (kind == MethodRecognizer::kFfiLoadFloat) {
          body += FloatToDouble();
        }
        body += Box(kUnboxedDouble);
      } else {
        body += Box(representation);
        if (kind == MethodRecognizer::kFfiLoadPointer) {
          const auto class_table = thread_->isolate()->class_table();
          ASSERT(class_table->HasValidClassAt(kFfiPointerCid));
          const auto& pointer_class =
              Class::ZoneHandle(H.zone(), class_table->At(kFfiPointerCid));

          // We find the reified type to use for the pointer allocation.
          //
          // Call sites to this recognized method are guaranteed to pass a
          // Pointer<Pointer<X>> as RawParameterVariable(0). This function
          // will return a Pointer<X> object - for which we inspect the
          // reified type on the argument.
          //
          // The following is safe to do, as (1) we are guaranteed to have a
          // Pointer<Pointer<X>> as argument, and (2) the bound on the pointer
          // type parameter guarantees X is an interface type.
          ASSERT(function.NumTypeParameters() == 1);
          LocalVariable* address = MakeTemporary();
          body += LoadLocal(parsed_function_->RawParameterVariable(0));
          body += LoadNativeField(
              Slot::GetTypeArgumentsSlotFor(thread_, pointer_class));
          body += LoadNativeField(Slot::GetTypeArgumentsIndexSlot(
              thread_, Pointer::kNativeTypeArgPos));
          body += LoadNativeField(Slot::Type_arguments());
          body += PushArgument();  // We instantiate a Pointer<X>.
          body += AllocateObject(TokenPosition::kNoSource, pointer_class, 1);
          LocalVariable* pointer = MakeTemporary();
          body += LoadLocal(pointer);
          body += LoadLocal(address);
          body += StoreInstanceField(TokenPosition::kNoSource,
                                     Slot::Pointer_c_memory_address());
          body += DropTempsPreserveTop(1);  // Drop [address] keep [pointer].
        }
      }
    } break;
    case MethodRecognizer::kFfiStoreInt8:
    case MethodRecognizer::kFfiStoreInt16:
    case MethodRecognizer::kFfiStoreInt32:
    case MethodRecognizer::kFfiStoreInt64:
    case MethodRecognizer::kFfiStoreUint8:
    case MethodRecognizer::kFfiStoreUint16:
    case MethodRecognizer::kFfiStoreUint32:
    case MethodRecognizer::kFfiStoreUint64:
    case MethodRecognizer::kFfiStoreIntPtr:
    case MethodRecognizer::kFfiStoreFloat:
    case MethodRecognizer::kFfiStoreDouble:
    case MethodRecognizer::kFfiStorePointer: {
      const classid_t ffi_type_arg_cid =
          compiler::ffi::RecognizedMethodTypeArgCid(kind);
      const classid_t typed_data_cid =
          compiler::ffi::ElementTypedDataCid(ffi_type_arg_cid);
      const Representation representation =
          compiler::ffi::TypeRepresentation(ffi_type_arg_cid);

      // Check Dart signature type.
      const auto& receiver_type =
          AbstractType::Handle(function.ParameterTypeAt(0));
      const auto& type_args = TypeArguments::Handle(receiver_type.arguments());
      const auto& type_arg = AbstractType::Handle(type_args.TypeAt(0));
      ASSERT(ffi_type_arg_cid == type_arg.type_class_id());

      LocalVariable* arg_pointer = parsed_function_->RawParameterVariable(0);
      LocalVariable* arg_index = parsed_function_->RawParameterVariable(1);
      LocalVariable* arg_value = parsed_function_->RawParameterVariable(2);

      if (kind == MethodRecognizer::kFfiStorePointer) {
        // Do type check before anything untagged is on the stack.
        const auto class_table = thread_->isolate()->class_table();
        ASSERT(class_table->HasValidClassAt(kFfiPointerCid));
        const auto& pointer_class =
            Class::ZoneHandle(H.zone(), class_table->At(kFfiPointerCid));
        const auto& pointer_type_args =
            TypeArguments::Handle(pointer_class.type_parameters());
        const auto& pointer_type_arg =
            AbstractType::Handle(pointer_type_args.TypeAt(0));

        // The method _storePointer is a top level generic function, not an
        // instance method on a generic class.
        ASSERT(!type_arg.IsInstantiated(kFunctions));
        ASSERT(type_arg.IsInstantiated(kCurrentClass));
        // But we type check it as a method on a generic class at runtime.
        body += LoadLocal(arg_value);
        body += LoadLocal(arg_pointer);
        body += CheckNullOptimized(TokenPosition::kNoSource,
                                   String::ZoneHandle(Z, function.name()));
        // We pass the Pointer type argument as instantiator_type_args.
        //
        // Call sites to this recognized method are guaranteed to pass a
        // Pointer<Pointer<X>> as RawParameterVariable(0). This function
        // will takes a Pointer<X> object - for which we inspect the
        // reified type on the argument.
        //
        // The following is safe to do, as (1) we are guaranteed to have a
        // Pointer<Pointer<X>> as argument, and (2) the bound on the pointer
        // type parameter guarantees X is an interface type.
        body += LoadNativeField(
            Slot::GetTypeArgumentsSlotFor(thread_, pointer_class));
        body += NullConstant();  // function_type_args.
        body += AssertAssignable(TokenPosition::kNoSource, pointer_type_arg,
                                 Symbols::Empty());
        body += Drop();
      }

      ASSERT(function.NumParameters() == 3);
      body += LoadLocal(arg_pointer);  // Pointer.
      body += CheckNullOptimized(TokenPosition::kNoSource,
                                 String::ZoneHandle(Z, function.name()));
      body += LoadNativeField(Slot::Pointer_c_memory_address());
      body += UnboxTruncate(kUnboxedFfiIntPtr);
      // We do Pointer.address + index * sizeOf<T> manually because LoadIndexed
      // does not support Mint index arguments.
      body += LoadLocal(arg_index);  // Index.
      body += CheckNullOptimized(TokenPosition::kNoSource,
                                 String::ZoneHandle(Z, function.name()));
      body += UnboxTruncate(kUnboxedFfiIntPtr);
      body += IntConstant(compiler::ffi::ElementSizeInBytes(ffi_type_arg_cid));
      body += UnboxTruncate(kUnboxedFfiIntPtr);
      // TODO(38831): Implement Shift for Uint32, and use that instead.
      body +=
          BinaryIntegerOp(Token::kMUL, kUnboxedFfiIntPtr, /* truncate= */ true);
      body +=
          BinaryIntegerOp(Token::kADD, kUnboxedFfiIntPtr, /* truncate= */ true);
      body += ConvertIntptrToUntagged();
      body += IntConstant(0);
      body += LoadLocal(arg_value);  // Value.
      body += CheckNullOptimized(TokenPosition::kNoSource,
                                 String::ZoneHandle(Z, function.name()));
      if (kind == MethodRecognizer::kFfiStorePointer) {
        body += LoadNativeField(Slot::Pointer_c_memory_address());
      } else if (kind == MethodRecognizer::kFfiStoreFloat ||
                 kind == MethodRecognizer::kFfiStoreDouble) {
        body += UnboxTruncate(kUnboxedDouble);
        if (kind == MethodRecognizer::kFfiStoreFloat) {
          body += DoubleToFloat();
        }
      } else {
        body += UnboxTruncate(representation);
      }
      body += StoreIndexedTypedData(typed_data_cid);
      body += NullConstant();
    } break;
    case MethodRecognizer::kFfiFromAddress: {
      const auto class_table = thread_->isolate()->class_table();
      ASSERT(class_table->HasValidClassAt(kFfiPointerCid));
      const auto& pointer_class =
          Class::ZoneHandle(H.zone(), class_table->At(kFfiPointerCid));

      ASSERT(function.NumTypeParameters() == 1);
      ASSERT(function.NumParameters() == 1);
      body += LoadLocal(parsed_function_->RawTypeArgumentsVariable());
      body += PushArgument();
      body += AllocateObject(TokenPosition::kNoSource, pointer_class, 1);
      body += LoadLocal(MakeTemporary());  // Duplicate Pointer.
      body += LoadLocal(parsed_function_->RawParameterVariable(0));  // Address.
      body += CheckNullOptimized(TokenPosition::kNoSource,
                                 String::ZoneHandle(Z, function.name()));
#if defined(TARGET_ARCH_IS_32_BIT)
      // Truncate to 32 bits on 32 bit architecture.
      body += UnboxTruncate(kUnboxedFfiIntPtr);
      body += Box(kUnboxedFfiIntPtr);
#endif  // defined(TARGET_ARCH_IS_32_BIT)
      body += StoreInstanceField(TokenPosition::kNoSource,
                                 Slot::Pointer_c_memory_address(),
                                 StoreInstanceFieldInstr::Kind::kInitializing);
    } break;
    case MethodRecognizer::kFfiGetAddress: {
      ASSERT(function.NumParameters() == 1);
      body += LoadLocal(parsed_function_->RawParameterVariable(0));  // Pointer.
      body += CheckNullOptimized(TokenPosition::kNoSource,
                                 String::ZoneHandle(Z, function.name()));
      body += LoadNativeField(Slot::Pointer_c_memory_address());
    } break;
    default: {
      UNREACHABLE();
      break;
    }
  }

  body += Return(TokenPosition::kNoSource, /* omit_result_type_check = */ true);

  return new (Z) FlowGraph(*parsed_function_, graph_entry_, last_used_block_id_,
                           prologue_info);
}

Fragment FlowGraphBuilder::BuildTypedDataViewFactoryConstructor(
    const Function& function,
    classid_t cid) {
  auto token_pos = function.token_pos();
  auto class_table = Thread::Current()->isolate()->class_table();

  ASSERT(class_table->HasValidClassAt(cid));
  const auto& view_class = Class::ZoneHandle(H.zone(), class_table->At(cid));

  ASSERT(function.IsFactory() && (function.NumParameters() == 4));
  LocalVariable* typed_data = parsed_function_->RawParameterVariable(1);
  LocalVariable* offset_in_bytes = parsed_function_->RawParameterVariable(2);
  LocalVariable* length = parsed_function_->RawParameterVariable(3);

  Fragment body;

  body += AllocateObject(token_pos, view_class, /*arg_count=*/0);
  LocalVariable* view_object = MakeTemporary();

  body += LoadLocal(view_object);
  body += LoadLocal(typed_data);
  body += StoreInstanceField(token_pos, Slot::TypedDataView_data(),
                             StoreInstanceFieldInstr::Kind::kInitializing);

  body += LoadLocal(view_object);
  body += LoadLocal(offset_in_bytes);
  body += StoreInstanceField(token_pos, Slot::TypedDataView_offset_in_bytes(),
                             StoreInstanceFieldInstr::Kind::kInitializing,
                             kNoStoreBarrier);

  body += LoadLocal(view_object);
  body += LoadLocal(length);
  body += StoreInstanceField(token_pos, Slot::TypedDataBase_length(),
                             StoreInstanceFieldInstr::Kind::kInitializing,
                             kNoStoreBarrier);

  // Update the inner pointer.
  //
  // WARNING: Notice that we assume here no GC happens between those 4
  // instructions!
  body += LoadLocal(view_object);
  body += LoadLocal(typed_data);
  body += LoadUntagged(compiler::target::TypedDataBase::data_field_offset());
  body += ConvertUntaggedToIntptr();
  body += LoadLocal(offset_in_bytes);
  body += UnboxSmiToIntptr();
  body += AddIntptrIntegers();
  body += ConvertIntptrToUntagged();
  body += StoreUntagged(compiler::target::TypedDataBase::data_field_offset());

  return body;
}

static const LocalScope* MakeImplicitClosureScope(Zone* Z, const Class& klass) {
  ASSERT(!klass.IsNull());
  // Note that if klass is _Closure, DeclarationType will be _Closure,
  // and not the signature type.
  Type& klass_type = Type::ZoneHandle(Z, klass.DeclarationType());

  LocalVariable* receiver_variable = new (Z)
      LocalVariable(TokenPosition::kNoSource, TokenPosition::kNoSource,
                    Symbols::This(), klass_type, /*param_type=*/nullptr);

  receiver_variable->set_is_captured();
  //  receiver_variable->set_is_final();
  LocalScope* scope = new (Z) LocalScope(NULL, 0, 0);
  scope->set_context_level(0);
  scope->AddVariable(receiver_variable);
  scope->AddContextVariable(receiver_variable);
  return scope;
}

Fragment FlowGraphBuilder::BuildImplicitClosureCreation(
    const Function& target) {
  Fragment fragment;
  fragment += AllocateClosure(TokenPosition::kNoSource, target);
  LocalVariable* closure = MakeTemporary();

  // The function signature can have uninstantiated class type parameters.
  if (!target.HasInstantiatedSignature(kCurrentClass)) {
    fragment += LoadLocal(closure);
    fragment += LoadInstantiatorTypeArguments();
    fragment += StoreInstanceField(
        TokenPosition::kNoSource, Slot::Closure_instantiator_type_arguments(),
        StoreInstanceFieldInstr::Kind::kInitializing);
  }

  // The function signature cannot have uninstantiated function type parameters,
  // because the function cannot be local and have parent generic functions.
  ASSERT(target.HasInstantiatedSignature(kFunctions));

  // Allocate a context that closes over `this`.
  // Note: this must be kept in sync with ScopeBuilder::BuildScopes.
  const LocalScope* implicit_closure_scope =
      MakeImplicitClosureScope(Z, Class::Handle(Z, target.Owner()));
  fragment += AllocateContext(implicit_closure_scope->context_slots());
  LocalVariable* context = MakeTemporary();

  // Store the function and the context in the closure.
  fragment += LoadLocal(closure);
  fragment += Constant(target);
  fragment +=
      StoreInstanceField(TokenPosition::kNoSource, Slot::Closure_function(),
                         StoreInstanceFieldInstr::Kind::kInitializing);

  fragment += LoadLocal(closure);
  fragment += LoadLocal(context);
  fragment +=
      StoreInstanceField(TokenPosition::kNoSource, Slot::Closure_context(),
                         StoreInstanceFieldInstr::Kind::kInitializing);

  if (target.IsGeneric()) {
    // Only generic functions need to have properly initialized
    // delayed_type_arguments.
    fragment += LoadLocal(closure);
    fragment += Constant(Object::empty_type_arguments());
    fragment += StoreInstanceField(
        TokenPosition::kNoSource, Slot::Closure_delayed_type_arguments(),
        StoreInstanceFieldInstr::Kind::kInitializing);
  }

  // The context is on top of the operand stack.  Store `this`.  The context
  // doesn't need a parent pointer because it doesn't close over anything
  // else.
  fragment += LoadLocal(parsed_function_->receiver_var());
  fragment += StoreInstanceField(
      TokenPosition::kNoSource,
      Slot::GetContextVariableSlotFor(
          thread_, *implicit_closure_scope->context_variables()[0]),
      StoreInstanceFieldInstr::Kind::kInitializing);

  return fragment;
}

Fragment FlowGraphBuilder::CheckVariableTypeInCheckedMode(
    const AbstractType& dst_type,
    const String& name_symbol) {
  return Fragment();
}

bool FlowGraphBuilder::NeedsDebugStepCheck(const Function& function,
                                           TokenPosition position) {
  return position.IsDebugPause() && !function.is_native() &&
         function.is_debuggable();
}

bool FlowGraphBuilder::NeedsDebugStepCheck(Value* value,
                                           TokenPosition position) {
  if (!position.IsDebugPause()) {
    return false;
  }
  Definition* definition = value->definition();
  if (definition->IsConstant() || definition->IsLoadStaticField()) {
    return true;
  }
  if (definition->IsAllocateObject()) {
    return !definition->AsAllocateObject()->closure_function().IsNull();
  }
  return definition->IsLoadLocal();
}

Fragment FlowGraphBuilder::EvaluateAssertion() {
  const Class& klass =
      Class::ZoneHandle(Z, Library::LookupCoreClass(Symbols::AssertionError()));
  ASSERT(!klass.IsNull());
  const Function& target = Function::ZoneHandle(
      Z, klass.LookupStaticFunctionAllowPrivate(Symbols::EvaluateAssertion()));
  ASSERT(!target.IsNull());
  return StaticCall(TokenPosition::kNoSource, target, /* argument_count = */ 1,
                    ICData::kStatic);
}

Fragment FlowGraphBuilder::CheckBoolean(TokenPosition position) {
  Fragment instructions;
  LocalVariable* top_of_stack = MakeTemporary();
  instructions += LoadLocal(top_of_stack);
  instructions += AssertBool(position);
  instructions += Drop();
  return instructions;
}

Fragment FlowGraphBuilder::CheckAssignable(const AbstractType& dst_type,
                                           const String& dst_name,
                                           AssertAssignableInstr::Kind kind) {
  Fragment instructions;
  if (!I->should_emit_strong_mode_checks()) {
    return Fragment();
  }
  if (!dst_type.IsDynamicType() && !dst_type.IsObjectType() &&
      !dst_type.IsVoidType()) {
    LocalVariable* top_of_stack = MakeTemporary();
    instructions += LoadLocal(top_of_stack);
    instructions += AssertAssignableLoadTypeArguments(TokenPosition::kNoSource,
                                                      dst_type, dst_name, kind);
    instructions += Drop();
  }
  return instructions;
}

Fragment FlowGraphBuilder::AssertAssignableLoadTypeArguments(
    TokenPosition position,
    const AbstractType& dst_type,
    const String& dst_name,
    AssertAssignableInstr::Kind kind) {
  if (!I->should_emit_strong_mode_checks()) {
    return Fragment();
  }

  Fragment instructions;

  if (!dst_type.IsInstantiated(kCurrentClass)) {
    instructions += LoadInstantiatorTypeArguments();
  } else {
    instructions += NullConstant();
  }

  if (!dst_type.IsInstantiated(kFunctions)) {
    instructions += LoadFunctionTypeArguments();
  } else {
    instructions += NullConstant();
  }

  instructions += AssertAssignable(position, dst_type, dst_name, kind);

  return instructions;
}

Fragment FlowGraphBuilder::AssertSubtype(TokenPosition position,
                                         const AbstractType& sub_type,
                                         const AbstractType& super_type,
                                         const String& dst_name) {
  Fragment instructions;

  instructions += LoadInstantiatorTypeArguments();
  Value* instantiator_type_args = Pop();
  instructions += LoadFunctionTypeArguments();
  Value* function_type_args = Pop();

  AssertSubtypeInstr* instr = new (Z)
      AssertSubtypeInstr(position, instantiator_type_args, function_type_args,
                         sub_type, super_type, dst_name, GetNextDeoptId());
  instructions += Fragment(instr);

  return instructions;
}

void FlowGraphBuilder::BuildArgumentTypeChecks(
    TypeChecksToBuild mode,
    Fragment* explicit_checks,
    Fragment* implicit_checks,
    Fragment* implicit_redefinitions) {
  if (!I->should_emit_strong_mode_checks()) return;
  const Function& dart_function = parsed_function_->function();

  const Function* forwarding_target = nullptr;
  if (parsed_function_->is_forwarding_stub()) {
    forwarding_target = parsed_function_->forwarding_stub_super_target();
    ASSERT(!forwarding_target->IsNull());
  }

  TypeArguments& type_parameters = TypeArguments::Handle(Z);
  if (dart_function.IsFactory()) {
    type_parameters = Class::Handle(Z, dart_function.Owner()).type_parameters();
  } else {
    type_parameters = dart_function.type_parameters();
  }
  intptr_t num_type_params = type_parameters.Length();
  if (forwarding_target != nullptr) {
    type_parameters = forwarding_target->type_parameters();
    ASSERT(type_parameters.Length() == num_type_params);
  }

  TypeParameter& type_param = TypeParameter::Handle(Z);
  String& name = String::Handle(Z);
  AbstractType& bound = AbstractType::Handle(Z);
  Fragment check_bounds;
  for (intptr_t i = 0; i < num_type_params; ++i) {
    type_param ^= type_parameters.TypeAt(i);

    bound = type_param.bound();
    if (bound.IsTopType()) {
      continue;
    }

    switch (mode) {
      case TypeChecksToBuild::kCheckAllTypeParameterBounds:
        break;
      case TypeChecksToBuild::kCheckCovariantTypeParameterBounds:
        if (!type_param.IsGenericCovariantImpl()) {
          continue;
        }
        break;
      case TypeChecksToBuild::kCheckNonCovariantTypeParameterBounds:
        if (type_param.IsGenericCovariantImpl()) {
          continue;
        }
        break;
    }

    name = type_param.name();

    ASSERT(type_param.IsFinalized());
    check_bounds +=
        AssertSubtype(TokenPosition::kNoSource, type_param, bound, name);
  }

  // Type arguments passed through partial instantiation are guaranteed to be
  // bounds-checked at the point of partial instantiation, so we don't need to
  // check them again at the call-site.
  if (dart_function.IsClosureFunction() && !check_bounds.is_empty() &&
      FLAG_eliminate_type_checks) {
    LocalVariable* closure = parsed_function_->ParameterVariable(0);
    *implicit_checks += TestDelayedTypeArgs(closure, /*present=*/{},
                                            /*absent=*/check_bounds);
  } else {
    *implicit_checks += check_bounds;
  }

  const intptr_t num_params = dart_function.NumParameters();
  for (intptr_t i = dart_function.NumImplicitParameters(); i < num_params;
       ++i) {
    LocalVariable* param = parsed_function_->ParameterVariable(i);
    if (!param->needs_type_check()) {
      continue;
    }

    const AbstractType* target_type = &param->type();
    if (forwarding_target != NULL) {
      // We add 1 to the parameter index to account for the receiver.
      target_type =
          &AbstractType::ZoneHandle(Z, forwarding_target->ParameterTypeAt(i));
    }

    if (target_type->IsTopType()) continue;

    const bool is_covariant = param->is_explicit_covariant_parameter();
    Fragment* checks = is_covariant ? explicit_checks : implicit_checks;

    *checks += LoadLocal(param);
    *checks += CheckAssignable(*target_type, param->name(),
                               AssertAssignableInstr::kParameterCheck);
    *checks += Drop();

    if (!is_covariant && implicit_redefinitions != nullptr && optimizing_) {
      // We generate slightly different code in optimized vs. un-optimized code,
      // which is ok since we don't allocate any deopt ids.
      AssertNoDeoptIdsAllocatedScope no_deopt_allocation(thread_);

      *implicit_redefinitions += LoadLocal(param);
      *implicit_redefinitions += RedefinitionWithType(*target_type);
      *implicit_redefinitions += StoreLocal(TokenPosition::kNoSource, param);
      *implicit_redefinitions += Drop();
    }
  }
}

BlockEntryInstr* FlowGraphBuilder::BuildPrologue(BlockEntryInstr* normal_entry,
                                                 PrologueInfo* prologue_info) {
  const bool compiling_for_osr = IsCompiledForOsr();

  kernel::PrologueBuilder prologue_builder(
      parsed_function_, last_used_block_id_, compiling_for_osr, IsInlining());
  BlockEntryInstr* instruction_cursor =
      prologue_builder.BuildPrologue(normal_entry, prologue_info);

  last_used_block_id_ = prologue_builder.last_used_block_id();

  return instruction_cursor;
}

RawArray* FlowGraphBuilder::GetOptionalParameterNames(
    const Function& function) {
  if (!function.HasOptionalNamedParameters()) {
    return Array::null();
  }

  const intptr_t num_fixed_params = function.num_fixed_parameters();
  const intptr_t num_opt_params = function.NumOptionalNamedParameters();
  const auto& names = Array::Handle(Z, Array::New(num_opt_params, Heap::kOld));
  auto& name = String::Handle(Z);
  for (intptr_t i = 0; i < num_opt_params; ++i) {
    name = function.ParameterNameAt(num_fixed_params + i);
    names.SetAt(i, name);
  }
  return names.raw();
}

Fragment FlowGraphBuilder::PushExplicitParameters(const Function& function) {
  Fragment instructions;
  for (intptr_t i = function.NumImplicitParameters(),
                n = function.NumParameters();
       i < n; ++i) {
    instructions += LoadLocal(parsed_function_->ParameterVariable(i));
    instructions += PushArgument();
  }
  return instructions;
}

FlowGraph* FlowGraphBuilder::BuildGraphOfMethodExtractor(
    const Function& method) {
  // A method extractor is the implicit getter for a method.
  const Function& function =
      Function::ZoneHandle(Z, method.extracted_method_closure());

  graph_entry_ =
      new (Z) GraphEntryInstr(*parsed_function_, Compiler::kNoOSRDeoptId);

  auto normal_entry = BuildFunctionEntry(graph_entry_);
  graph_entry_->set_normal_entry(normal_entry);

  Fragment body(normal_entry);
  body += CheckStackOverflowInPrologue(method.token_pos());
  body += BuildImplicitClosureCreation(function);
  body += Return(TokenPosition::kNoSource);

  // There is no prologue code for a method extractor.
  PrologueInfo prologue_info(-1, -1);
  return new (Z) FlowGraph(*parsed_function_, graph_entry_, last_used_block_id_,
                           prologue_info);
}

FlowGraph* FlowGraphBuilder::BuildGraphOfNoSuchMethodDispatcher(
    const Function& function) {
  // This function is specialized for a receiver class, a method name, and
  // the arguments descriptor at a call site.

  graph_entry_ =
      new (Z) GraphEntryInstr(*parsed_function_, Compiler::kNoOSRDeoptId);

  auto normal_entry = BuildFunctionEntry(graph_entry_);
  graph_entry_->set_normal_entry(normal_entry);

  PrologueInfo prologue_info(-1, -1);
  BlockEntryInstr* instruction_cursor =
      BuildPrologue(normal_entry, &prologue_info);

  // The backend will expect an array of default values for all the named
  // parameters, even if they are all known to be passed at the call site
  // because the call site matches the arguments descriptor.  Use null for
  // the default values.
  const Array& descriptor_array =
      Array::ZoneHandle(Z, function.saved_args_desc());
  ArgumentsDescriptor descriptor(descriptor_array);
  ZoneGrowableArray<const Instance*>* default_values =
      new ZoneGrowableArray<const Instance*>(Z, descriptor.NamedCount());
  for (intptr_t i = 0; i < descriptor.NamedCount(); ++i) {
    default_values->Add(&Object::null_instance());
  }
  parsed_function_->set_default_parameter_values(default_values);

  Fragment body(instruction_cursor);
  body += CheckStackOverflowInPrologue(function.token_pos());

  // The receiver is the first argument to noSuchMethod, and it is the first
  // argument passed to the dispatcher function.
  body += LoadLocal(parsed_function_->ParameterVariable(0));
  body += PushArgument();

  // The second argument to noSuchMethod is an invocation mirror.  Push the
  // arguments for allocating the invocation mirror.  First, the name.
  body += Constant(String::ZoneHandle(Z, function.name()));
  body += PushArgument();

  // Second, the arguments descriptor.
  body += Constant(descriptor_array);
  body += PushArgument();

  // Third, an array containing the original arguments.  Create it and fill
  // it in.
  const intptr_t receiver_index = descriptor.TypeArgsLen() > 0 ? 1 : 0;
  body += Constant(TypeArguments::ZoneHandle(Z, TypeArguments::null()));
  body += IntConstant(receiver_index + descriptor.Count());
  body += CreateArray();
  LocalVariable* array = MakeTemporary();
  if (receiver_index > 0) {
    LocalVariable* type_args = parsed_function_->function_type_arguments();
    ASSERT(type_args != NULL);
    body += LoadLocal(array);
    body += IntConstant(0);
    body += LoadLocal(type_args);
    body += StoreIndexed(kArrayCid);
  }
  for (intptr_t i = 0; i < descriptor.PositionalCount(); ++i) {
    body += LoadLocal(array);
    body += IntConstant(receiver_index + i);
    body += LoadLocal(parsed_function_->ParameterVariable(i));
    body += StoreIndexed(kArrayCid);
  }
  String& name = String::Handle(Z);
  for (intptr_t i = 0; i < descriptor.NamedCount(); ++i) {
    intptr_t parameter_index = descriptor.PositionalCount() + i;
    name = descriptor.NameAt(i);
    name = Symbols::New(H.thread(), name);
    body += LoadLocal(array);
    body += IntConstant(receiver_index + descriptor.PositionAt(i));
    body += LoadLocal(parsed_function_->ParameterVariable(parameter_index));
    body += StoreIndexed(kArrayCid);
  }
  body += PushArgument();

  // Fourth, false indicating this is not a super NoSuchMethod.
  body += Constant(Bool::False());
  body += PushArgument();

  const Class& mirror_class =
      Class::Handle(Z, Library::LookupCoreClass(Symbols::InvocationMirror()));
  ASSERT(!mirror_class.IsNull());
  const Function& allocation_function = Function::ZoneHandle(
      Z, mirror_class.LookupStaticFunction(
             Library::PrivateCoreLibName(Symbols::AllocateInvocationMirror())));
  ASSERT(!allocation_function.IsNull());
  body += StaticCall(TokenPosition::kMinSource, allocation_function,
                     /* argument_count = */ 4, ICData::kStatic);
  body += PushArgument();  // For the call to noSuchMethod.

  const int kTypeArgsLen = 0;
  ArgumentsDescriptor two_arguments(
      Array::Handle(Z, ArgumentsDescriptor::New(kTypeArgsLen, 2)));
  Function& no_such_method =
      Function::ZoneHandle(Z, Resolver::ResolveDynamicForReceiverClass(
                                  Class::Handle(Z, function.Owner()),
                                  Symbols::NoSuchMethod(), two_arguments));
  if (no_such_method.IsNull()) {
    // If noSuchMethod is not found on the receiver class, call
    // Object.noSuchMethod.
    no_such_method = Resolver::ResolveDynamicForReceiverClass(
        Class::Handle(Z, I->object_store()->object_class()),
        Symbols::NoSuchMethod(), two_arguments);
  }
  body += StaticCall(TokenPosition::kMinSource, no_such_method,
                     /* argument_count = */ 2, ICData::kNSMDispatch);
  body += Return(TokenPosition::kNoSource);

  return new (Z) FlowGraph(*parsed_function_, graph_entry_, last_used_block_id_,
                           prologue_info);
}

FlowGraph* FlowGraphBuilder::BuildGraphOfInvokeFieldDispatcher(
    const Function& function) {
  // Find the name of the field we should dispatch to.
  const Class& owner = Class::Handle(Z, function.Owner());
  ASSERT(!owner.IsNull());
  const String& field_name = String::Handle(Z, function.name());
  const String& getter_name = String::ZoneHandle(
      Z, Symbols::New(thread_,
                      String::Handle(Z, Field::GetterSymbol(field_name))));

  // Determine if this is `class Closure { get call => this; }`
  const Class& closure_class =
      Class::Handle(Z, I->object_store()->closure_class());
  const bool is_closure_call = (owner.raw() == closure_class.raw()) &&
                               field_name.Equals(Symbols::Call());

  // Set default parameters & construct argument names array.
  //
  // The backend will expect an array of default values for all the named
  // parameters, even if they are all known to be passed at the call site
  // because the call site matches the arguments descriptor.  Use null for
  // the default values.
  const Array& descriptor_array =
      Array::ZoneHandle(Z, function.saved_args_desc());
  ArgumentsDescriptor descriptor(descriptor_array);
  const Array& argument_names =
      Array::ZoneHandle(Z, Array::New(descriptor.NamedCount(), Heap::kOld));
  ZoneGrowableArray<const Instance*>* default_values =
      new ZoneGrowableArray<const Instance*>(Z, descriptor.NamedCount());
  String& string_handle = String::Handle(Z);
  for (intptr_t i = 0; i < descriptor.NamedCount(); ++i) {
    default_values->Add(&Object::null_instance());
    string_handle = descriptor.NameAt(i);
    argument_names.SetAt(i, string_handle);
  }
  parsed_function_->set_default_parameter_values(default_values);

  graph_entry_ =
      new (Z) GraphEntryInstr(*parsed_function_, Compiler::kNoOSRDeoptId);

  auto normal_entry = BuildFunctionEntry(graph_entry_);
  graph_entry_->set_normal_entry(normal_entry);

  PrologueInfo prologue_info(-1, -1);
  BlockEntryInstr* instruction_cursor =
      BuildPrologue(normal_entry, &prologue_info);

  Fragment body(instruction_cursor);
  body += CheckStackOverflowInPrologue(function.token_pos());

  if (descriptor.TypeArgsLen() > 0) {
    LocalVariable* type_args = parsed_function_->function_type_arguments();
    ASSERT(type_args != NULL);
    body += LoadLocal(type_args);
    body += PushArgument();
  }

  LocalVariable* closure = NULL;
  if (is_closure_call) {
    closure = parsed_function_->ParameterVariable(0);

    // The closure itself is the first argument.
    body += LoadLocal(closure);
  } else {
    // Invoke the getter to get the field value.
    body += LoadLocal(parsed_function_->ParameterVariable(0));
    body += PushArgument();
    const intptr_t kTypeArgsLen = 0;
    const intptr_t kNumArgsChecked = 1;
    body += InstanceCall(TokenPosition::kMinSource, getter_name, Token::kGET,
                         kTypeArgsLen, 1, Array::null_array(), kNumArgsChecked,
                         Function::null_function());
  }

  body += PushArgument();

  // Push all arguments onto the stack.
  intptr_t pos = 1;
  for (; pos < descriptor.Count(); pos++) {
    body += LoadLocal(parsed_function_->ParameterVariable(pos));
    body += PushArgument();
  }

  if (is_closure_call) {
    // Lookup the function in the closure.
    body += LoadLocal(closure);
    body += LoadNativeField(Slot::Closure_function());

    body += ClosureCall(TokenPosition::kNoSource, descriptor.TypeArgsLen(),
                        descriptor.Count(), argument_names);
  } else {
    const intptr_t kNumArgsChecked = 1;
    body += InstanceCall(TokenPosition::kMinSource, Symbols::Call(),
                         Token::kILLEGAL, descriptor.TypeArgsLen(),
                         descriptor.Count(), argument_names, kNumArgsChecked,
                         Function::null_function());
  }

  body += Return(TokenPosition::kNoSource);

  return new (Z) FlowGraph(*parsed_function_, graph_entry_, last_used_block_id_,
                           prologue_info);
}

FlowGraph* FlowGraphBuilder::BuildGraphOfNoSuchMethodForwarder(
    const Function& function,
    bool is_implicit_closure_function,
    bool throw_no_such_method_error) {
  graph_entry_ =
      new (Z) GraphEntryInstr(*parsed_function_, Compiler::kNoOSRDeoptId);

  auto normal_entry = BuildFunctionEntry(graph_entry_);
  graph_entry_->set_normal_entry(normal_entry);

  PrologueInfo prologue_info(-1, -1);
  BlockEntryInstr* instruction_cursor =
      BuildPrologue(normal_entry, &prologue_info);

  Fragment body(instruction_cursor);
  body += CheckStackOverflowInPrologue(function.token_pos());

  // If we are inside the tearoff wrapper function (implicit closure), we need
  // to extract the receiver from the context. We just replace it directly on
  // the stack to simplify the rest of the code.
  if (is_implicit_closure_function && !function.is_static()) {
    if (parsed_function_->has_arg_desc_var()) {
      body += LoadArgDescriptor();
      body += LoadNativeField(Slot::ArgumentsDescriptor_count());
      body += LoadLocal(parsed_function_->current_context_var());
      body += LoadNativeField(Slot::GetContextVariableSlotFor(
          thread_, *parsed_function_->receiver_var()));
      body += StoreFpRelativeSlot(
          kWordSize * compiler::target::frame_layout.param_end_from_fp);
    } else {
      body += LoadLocal(parsed_function_->current_context_var());
      body += LoadNativeField(Slot::GetContextVariableSlotFor(
          thread_, *parsed_function_->receiver_var()));
      body += StoreFpRelativeSlot(
          kWordSize * (compiler::target::frame_layout.param_end_from_fp +
                       function.NumParameters()));
    }
  }

  if (function.NeedsArgumentTypeChecks(I)) {
    BuildArgumentTypeChecks(TypeChecksToBuild::kCheckAllTypeParameterBounds,
                            &body, &body, nullptr);
  }

  body += MakeTemp();
  LocalVariable* result = MakeTemporary();

  // Do "++argument_count" if any type arguments were passed.
  LocalVariable* argument_count_var = parsed_function_->expression_temp_var();
  body += IntConstant(0);
  body += StoreLocal(TokenPosition::kNoSource, argument_count_var);
  body += Drop();
  if (function.IsGeneric()) {
    Fragment then;
    Fragment otherwise;
    otherwise += IntConstant(1);
    otherwise += StoreLocal(TokenPosition::kNoSource, argument_count_var);
    otherwise += Drop();
    body += TestAnyTypeArgs(then, otherwise);
  }

  if (function.HasOptionalParameters()) {
    body += LoadArgDescriptor();
    body += LoadNativeField(Slot::ArgumentsDescriptor_count());
  } else {
    body += IntConstant(function.NumParameters());
  }
  body += LoadLocal(argument_count_var);
  body += SmiBinaryOp(Token::kADD, /* truncate= */ true);
  LocalVariable* argument_count = MakeTemporary();

  // We are generating code like the following:
  //
  // var arguments = new Array<dynamic>(argument_count);
  //
  // int i = 0;
  // if (any type arguments are passed) {
  //   arguments[0] = function_type_arguments;
  //   ++i;
  // }
  //
  // for (; i < argument_count; ++i) {
  //   arguments[i] = LoadFpRelativeSlot(
  //       kWordSize * (frame_layout.param_end_from_fp + argument_count - i));
  // }
  body += Constant(TypeArguments::ZoneHandle(Z, TypeArguments::null()));
  body += LoadLocal(argument_count);
  body += CreateArray();
  LocalVariable* arguments = MakeTemporary();

  {
    // int i = 0
    LocalVariable* index = parsed_function_->expression_temp_var();
    body += IntConstant(0);
    body += StoreLocal(TokenPosition::kNoSource, index);
    body += Drop();

    // if (any type arguments are passed) {
    //   arguments[0] = function_type_arguments;
    //   i = 1;
    // }
    if (function.IsGeneric()) {
      Fragment store;
      store += LoadLocal(arguments);
      store += IntConstant(0);
      store += LoadFunctionTypeArguments();
      store += StoreIndexed(kArrayCid);
      store += IntConstant(1);
      store += StoreLocal(TokenPosition::kNoSource, index);
      store += Drop();
      body += TestAnyTypeArgs(store, Fragment());
    }

    TargetEntryInstr* body_entry;
    TargetEntryInstr* loop_exit;

    Fragment condition;
    // i < argument_count
    condition += LoadLocal(index);
    condition += LoadLocal(argument_count);
    condition += SmiRelationalOp(Token::kLT);
    condition += BranchIfTrue(&body_entry, &loop_exit, /*negate=*/false);

    Fragment loop_body(body_entry);

    // arguments[i] = LoadFpRelativeSlot(
    //     kWordSize * (frame_layout.param_end_from_fp + argument_count - i));
    loop_body += LoadLocal(arguments);
    loop_body += LoadLocal(index);
    loop_body += LoadLocal(argument_count);
    loop_body += LoadLocal(index);
    loop_body += SmiBinaryOp(Token::kSUB, /*truncate=*/true);
    loop_body +=
        LoadFpRelativeSlot(compiler::target::kWordSize *
                               compiler::target::frame_layout.param_end_from_fp,
                           CompileType::Dynamic());
    loop_body += StoreIndexed(kArrayCid);

    // ++i
    loop_body += LoadLocal(index);
    loop_body += IntConstant(1);
    loop_body += SmiBinaryOp(Token::kADD, /*truncate=*/true);
    loop_body += StoreLocal(TokenPosition::kNoSource, index);
    loop_body += Drop();

    JoinEntryInstr* join = BuildJoinEntry();
    loop_body += Goto(join);

    Fragment loop(join);
    loop += condition;

    Instruction* entry =
        new (Z) GotoInstr(join, CompilerState::Current().GetNextDeoptId());
    body += Fragment(entry, loop_exit);
  }

  // Load receiver.
  if (is_implicit_closure_function) {
    if (throw_no_such_method_error) {
      const Function& parent =
          Function::ZoneHandle(Z, function.parent_function());
      const Class& owner = Class::ZoneHandle(Z, parent.Owner());
      AbstractType& type = AbstractType::ZoneHandle(Z);
      type = Type::New(owner, TypeArguments::Handle(Z), owner.token_pos(),
                       Heap::kOld);
      type = ClassFinalizer::FinalizeType(owner, type);
      body += Constant(type);
    } else {
      body += LoadLocal(parsed_function_->current_context_var());
      body += LoadNativeField(Slot::GetContextVariableSlotFor(
          thread_, *parsed_function_->receiver_var()));
    }
  } else {
    body += LoadLocal(parsed_function_->ParameterVariable(0));
  }
  body += PushArgument();

  body += Constant(String::ZoneHandle(Z, function.name()));
  body += PushArgument();

  if (!parsed_function_->has_arg_desc_var()) {
    // If there is no variable for the arguments descriptor (this function's
    // signature doesn't require it), then we need to create one.
    Array& args_desc = Array::ZoneHandle(
        Z, ArgumentsDescriptor::New(0, function.NumParameters()));
    body += Constant(args_desc);
  } else {
    body += LoadArgDescriptor();
  }
  body += PushArgument();

  body += LoadLocal(arguments);
  body += PushArgument();

  if (throw_no_such_method_error) {
    const Function& parent =
        Function::ZoneHandle(Z, function.parent_function());
    const Class& owner = Class::ZoneHandle(Z, parent.Owner());
    InvocationMirror::Level im_level = owner.IsTopLevel()
                                           ? InvocationMirror::kTopLevel
                                           : InvocationMirror::kStatic;
    InvocationMirror::Kind im_kind;
    if (function.IsImplicitGetterFunction() || function.IsGetterFunction()) {
      im_kind = InvocationMirror::kGetter;
    } else if (function.IsImplicitSetterFunction() ||
               function.IsSetterFunction()) {
      im_kind = InvocationMirror::kSetter;
    } else {
      im_kind = InvocationMirror::kMethod;
    }
    body += IntConstant(InvocationMirror::EncodeType(im_level, im_kind));
  } else {
    body += NullConstant();
  }
  body += PushArgument();

  // Push the number of delayed type arguments.
  if (function.IsClosureFunction()) {
    LocalVariable* closure = parsed_function_->ParameterVariable(0);
    Fragment then;
    then += IntConstant(function.NumTypeParameters());
    then += StoreLocal(TokenPosition::kNoSource, argument_count_var);
    then += Drop();
    Fragment otherwise;
    otherwise += IntConstant(0);
    otherwise += StoreLocal(TokenPosition::kNoSource, argument_count_var);
    otherwise += Drop();
    body += TestDelayedTypeArgs(closure, then, otherwise);
    body += LoadLocal(argument_count_var);
  } else {
    body += IntConstant(0);
  }
  body += PushArgument();

  const Class& mirror_class =
      Class::Handle(Z, Library::LookupCoreClass(Symbols::InvocationMirror()));
  ASSERT(!mirror_class.IsNull());
  const Function& allocation_function = Function::ZoneHandle(
      Z, mirror_class.LookupStaticFunction(Library::PrivateCoreLibName(
             Symbols::AllocateInvocationMirrorForClosure())));
  ASSERT(!allocation_function.IsNull());
  body += StaticCall(TokenPosition::kMinSource, allocation_function,
                     /* argument_count = */ 5, ICData::kStatic);
  body += PushArgument();  // For the call to noSuchMethod.

  if (throw_no_such_method_error) {
    const Class& klass = Class::ZoneHandle(
        Z, Library::LookupCoreClass(Symbols::NoSuchMethodError()));
    ASSERT(!klass.IsNull());
    const Function& throw_function = Function::ZoneHandle(
        Z,
        klass.LookupStaticFunctionAllowPrivate(Symbols::ThrowNewInvocation()));
    ASSERT(!throw_function.IsNull());
    body += StaticCall(TokenPosition::kNoSource, throw_function, 2,
                       ICData::kStatic);
  } else {
    body += InstanceCall(
        TokenPosition::kNoSource, Symbols::NoSuchMethod(), Token::kILLEGAL,
        /*type_args_len=*/0, /*argument_count=*/2, Array::null_array(),
        /*checked_argument_count=*/1, Function::null_function());
  }
  body += StoreLocal(TokenPosition::kNoSource, result);
  body += Drop();

  body += Drop();  // arguments
  body += Drop();  // argument count

  AbstractType& return_type = AbstractType::Handle(function.result_type());
  if (!return_type.IsDynamicType() && !return_type.IsVoidType() &&
      !return_type.IsObjectType()) {
    body += AssertAssignableLoadTypeArguments(TokenPosition::kNoSource,
                                              return_type, Symbols::Empty());
  }
  body += Return(TokenPosition::kNoSource);

  return new (Z) FlowGraph(*parsed_function_, graph_entry_, last_used_block_id_,
                           prologue_info);
}

Fragment FlowGraphBuilder::BuildDefaultTypeHandling(const Function& function) {
  if (function.IsGeneric()) {
    const TypeArguments& default_types =
        parsed_function_->DefaultFunctionTypeArguments();

    if (!default_types.IsNull()) {
      Fragment then;
      Fragment otherwise;

      otherwise += TranslateInstantiatedTypeArguments(default_types);
      otherwise += StoreLocal(TokenPosition::kNoSource,
                              parsed_function_->function_type_arguments());
      otherwise += Drop();
      return TestAnyTypeArgs(then, otherwise);
    }
  }
  return Fragment();
}

FunctionEntryInstr* FlowGraphBuilder::BuildSharedUncheckedEntryPoint(
    Fragment shared_prologue_linked_in,
    Fragment skippable_checks,
    Fragment redefinitions_if_skipped,
    Fragment body) {
  ASSERT(shared_prologue_linked_in.entry == graph_entry_->normal_entry());
  ASSERT(parsed_function_->has_entry_points_temp_var());
  Instruction* prologue_start = shared_prologue_linked_in.entry->next();

  auto* join_entry = BuildJoinEntry();

  Fragment normal_entry(shared_prologue_linked_in.entry);
  normal_entry +=
      IntConstant(static_cast<intptr_t>(UncheckedEntryPointStyle::kNone));
  normal_entry += StoreLocal(TokenPosition::kNoSource,
                             parsed_function_->entry_points_temp_var());
  normal_entry += Drop();
  normal_entry += Goto(join_entry);

  auto* extra_target_entry = BuildFunctionEntry(graph_entry_);
  Fragment extra_entry(extra_target_entry);
  extra_entry += IntConstant(
      static_cast<intptr_t>(UncheckedEntryPointStyle::kSharedWithVariable));
  extra_entry += StoreLocal(TokenPosition::kNoSource,
                            parsed_function_->entry_points_temp_var());
  extra_entry += Drop();
  extra_entry += Goto(join_entry);

  if (prologue_start != nullptr) {
    join_entry->LinkTo(prologue_start);
  } else {
    // Prologue is empty.
    shared_prologue_linked_in.current = join_entry;
  }

  TargetEntryInstr *do_checks, *skip_checks;
  shared_prologue_linked_in +=
      LoadLocal(parsed_function_->entry_points_temp_var());
  shared_prologue_linked_in += BuildEntryPointsIntrospection();
  shared_prologue_linked_in +=
      LoadLocal(parsed_function_->entry_points_temp_var());
  shared_prologue_linked_in += IntConstant(
      static_cast<intptr_t>(UncheckedEntryPointStyle::kSharedWithVariable));
  shared_prologue_linked_in +=
      BranchIfEqual(&skip_checks, &do_checks, /*negate=*/false);

  JoinEntryInstr* rest_entry = BuildJoinEntry();

  Fragment(do_checks) + skippable_checks + Goto(rest_entry);
  Fragment(skip_checks) + redefinitions_if_skipped + Goto(rest_entry);
  Fragment(rest_entry) + body;

  return extra_target_entry;
}

FunctionEntryInstr* FlowGraphBuilder::BuildSeparateUncheckedEntryPoint(
    BlockEntryInstr* normal_entry,
    Fragment normal_prologue,
    Fragment extra_prologue,
    Fragment shared_prologue,
    Fragment body) {
  auto* join_entry = BuildJoinEntry();
  auto* extra_entry = BuildFunctionEntry(graph_entry_);

  Fragment normal(normal_entry);
  normal += IntConstant(static_cast<intptr_t>(UncheckedEntryPointStyle::kNone));
  normal += BuildEntryPointsIntrospection();
  normal += normal_prologue;
  normal += Goto(join_entry);

  Fragment extra(extra_entry);
  extra +=
      IntConstant(static_cast<intptr_t>(UncheckedEntryPointStyle::kSeparate));
  extra += BuildEntryPointsIntrospection();
  extra += extra_prologue;
  extra += Goto(join_entry);

  Fragment(join_entry) + shared_prologue + body;
  return extra_entry;
}

FlowGraph* FlowGraphBuilder::BuildGraphOfImplicitClosureFunction(
    const Function& function) {
  const Function& parent = Function::ZoneHandle(Z, function.parent_function());
  const String& func_name = String::ZoneHandle(Z, parent.name());
  const Class& owner = Class::ZoneHandle(Z, parent.Owner());
  Function& target = Function::ZoneHandle(Z, owner.LookupFunction(func_name));

  if (!target.IsNull() && (target.raw() != parent.raw())) {
    DEBUG_ASSERT(Isolate::Current()->HasAttemptedReload());
    if ((target.is_static() != parent.is_static()) ||
        (target.kind() != parent.kind())) {
      target = Function::null();
    }
  }

  if (target.IsNull() ||
      (parent.num_fixed_parameters() != target.num_fixed_parameters())) {
    return BuildGraphOfNoSuchMethodForwarder(function, true,
                                             parent.is_static());
  }

  graph_entry_ =
      new (Z) GraphEntryInstr(*parsed_function_, Compiler::kNoOSRDeoptId);

  auto normal_entry = BuildFunctionEntry(graph_entry_);
  graph_entry_->set_normal_entry(normal_entry);

  PrologueInfo prologue_info(-1, -1);
  BlockEntryInstr* instruction_cursor =
      BuildPrologue(normal_entry, &prologue_info);

  const Fragment prologue = CheckStackOverflowInPrologue(function.token_pos());

  const Fragment default_type_handling = BuildDefaultTypeHandling(function);

  // We're going to throw away the explicit checks because the target will
  // always check them.
  Fragment implicit_checks;
  if (function.NeedsArgumentTypeChecks(I)) {
    Fragment explicit_checks_unused;
    if (target.is_static()) {
      // Tearoffs of static methods needs to perform arguments checks since
      // static methods they forward to don't do it themselves.
      BuildArgumentTypeChecks(TypeChecksToBuild::kCheckAllTypeParameterBounds,
                              &explicit_checks_unused, &implicit_checks,
                              nullptr);
    } else {
      if (MethodCanSkipTypeChecksForNonCovariantArguments(
              parent, ProcedureAttributesMetadata())) {
        // Generate checks that are skipped inside a body of a function.
        BuildArgumentTypeChecks(
            TypeChecksToBuild::kCheckNonCovariantTypeParameterBounds,
            &explicit_checks_unused, &implicit_checks, nullptr);
      }
    }
  }

  Fragment body;

  intptr_t type_args_len = 0;
  if (function.IsGeneric()) {
    type_args_len = function.NumTypeParameters();
    ASSERT(parsed_function_->function_type_arguments() != NULL);
    body += LoadLocal(parsed_function_->function_type_arguments());
    body += PushArgument();
  }

  // Push receiver.
  if (!target.is_static()) {
    // The context has a fixed shape: a single variable which is the
    // closed-over receiver.
    body += LoadLocal(parsed_function_->ParameterVariable(0));
    body += LoadNativeField(Slot::Closure_context());
    body += LoadNativeField(Slot::GetContextVariableSlotFor(
        thread_, *parsed_function_->receiver_var()));
    body += PushArgument();
  }

  body += PushExplicitParameters(function);

  // Forward parameters to the target.
  intptr_t argument_count = function.NumParameters() -
                            function.NumImplicitParameters() +
                            (target.is_static() ? 0 : 1);
  ASSERT(argument_count == target.NumParameters());

  Array& argument_names =
      Array::ZoneHandle(Z, GetOptionalParameterNames(function));

  body += StaticCall(TokenPosition::kNoSource, target, argument_count,
                     argument_names, ICData::kNoRebind,
                     /* result_type = */ NULL, type_args_len);

  // Return the result.
  body += Return(function.end_token_pos());

  // Setup multiple entrypoints if useful.
  FunctionEntryInstr* extra_entry = nullptr;
  if (function.MayHaveUncheckedEntryPoint(I)) {
    // The prologue for a closure will always have context handling (e.g.
    // setting up the receiver variable), but we don't need it on the unchecked
    // entry because the only time we reference this is for loading the
    // receiver, which we fetch directly from the context.
    if (PrologueBuilder::PrologueSkippableOnUncheckedEntry(function)) {
      // Use separate entry points since we can skip almost everything on the
      // static entry.
      extra_entry = BuildSeparateUncheckedEntryPoint(
          /*normal_entry=*/instruction_cursor,
          /*normal_prologue=*/prologue + default_type_handling +
              implicit_checks,
          /*extra_prologue=*/
          CheckStackOverflowInPrologue(function.token_pos()),
          /*shared_prologue=*/Fragment(),
          /*body=*/body);
    } else {
      Fragment shared_prologue(normal_entry, instruction_cursor);
      shared_prologue += prologue;
      extra_entry = BuildSharedUncheckedEntryPoint(
          /*shared_prologue_linked_in=*/shared_prologue,
          /*skippable_checks=*/default_type_handling + implicit_checks,
          /*redefinitions_if_skipped=*/Fragment(),
          /*body=*/body);
    }
    RecordUncheckedEntryPoint(graph_entry_, extra_entry);
  } else {
    Fragment function(instruction_cursor);
    function += prologue;
    function += default_type_handling;
    function += implicit_checks;
    function += body;
  }

  return new (Z) FlowGraph(*parsed_function_, graph_entry_, last_used_block_id_,
                           prologue_info);
}

FlowGraph* FlowGraphBuilder::BuildGraphOfFieldAccessor(
    const Function& function) {
  ASSERT(function.IsImplicitGetterOrSetter() ||
         function.IsDynamicInvocationForwarder());

  // Instead of building a dynamic invocation forwarder that checks argument
  // type and then invokes original setter we simply generate the type check
  // and inlined field store. Scope builder takes care of setting correct
  // type check mode in this case.
  const bool is_setter = function.IsDynamicInvocationForwarder() ||
                         function.IsImplicitSetterFunction();
  const bool is_method = !function.IsStaticFunction();

  Field& field = Field::ZoneHandle(Z);
  if (function.IsDynamicInvocationForwarder()) {
    Function& target = Function::Handle(function.ForwardingTarget());
    field = target.accessor_field();
  } else {
    field = function.accessor_field();
  }

  graph_entry_ =
      new (Z) GraphEntryInstr(*parsed_function_, Compiler::kNoOSRDeoptId);

  auto normal_entry = BuildFunctionEntry(graph_entry_);
  graph_entry_->set_normal_entry(normal_entry);

  Fragment body(normal_entry);
  if (is_setter) {
    LocalVariable* setter_value =
        parsed_function_->ParameterVariable(is_method ? 1 : 0);

    // We only expect to generate a dynamic invocation forwarder if
    // the value needs type check.
    ASSERT(!function.IsDynamicInvocationForwarder() ||
           setter_value->needs_type_check());
    if (is_method) {
      body += LoadLocal(parsed_function_->ParameterVariable(0));
    }
    body += LoadLocal(setter_value);
    if (I->argument_type_checks() && setter_value->needs_type_check()) {
      body += CheckAssignable(setter_value->type(), setter_value->name(),
                              AssertAssignableInstr::kParameterCheck);
    }
    if (is_method) {
      body += StoreInstanceFieldGuarded(field,
                                        StoreInstanceFieldInstr::Kind::kOther);
    } else {
      body += StoreStaticField(TokenPosition::kNoSource, field);
    }
    body += NullConstant();
  } else if (is_method) {
    body += LoadLocal(parsed_function_->ParameterVariable(0));
    body += LoadField(field);
  } else if (field.is_const()) {
    // If the parser needs to know the value of an uninitialized constant field
    // it will set the value to the transition sentinel (used to detect circular
    // initialization) and then call the implicit getter.  Thus, the getter
    // cannot contain the InitStaticField instruction that normal static getters
    // contain because it would detect spurious circular initialization when it
    // checks for the transition sentinel.
    ASSERT(!field.IsUninitialized());
    body += Constant(Instance::ZoneHandle(Z, field.StaticValue()));
  } else {
    // The field always has an initializer because static fields without
    // initializers are initialized eagerly and do not have implicit getters.
    ASSERT(field.has_initializer());
    body += Constant(field);
    body += InitStaticField(field);
    body += Constant(field);
    body += LoadStaticField();
  }
  body += Return(TokenPosition::kNoSource);

  PrologueInfo prologue_info(-1, -1);
  return new (Z) FlowGraph(*parsed_function_, graph_entry_, last_used_block_id_,
                           prologue_info);
}

FlowGraph* FlowGraphBuilder::BuildGraphOfDynamicInvocationForwarder(
    const Function& function) {
  auto& name = String::Handle(Z, function.name());
  name = Function::DemangleDynamicInvocationForwarderName(name);
  const auto& owner = Class::Handle(Z, function.Owner());
  const auto& target =
      Function::ZoneHandle(Z, owner.LookupDynamicFunction(name));
  ASSERT(!target.IsNull());
  ASSERT(!target.IsImplicitGetterFunction());

  if (target.IsImplicitSetterFunction()) {
    return BuildGraphOfFieldAccessor(function);
  }

  graph_entry_ = new (Z) GraphEntryInstr(*parsed_function_, osr_id_);

  auto normal_entry = BuildFunctionEntry(graph_entry_);
  graph_entry_->set_normal_entry(normal_entry);

  PrologueInfo prologue_info(-1, -1);
  auto instruction_cursor = BuildPrologue(normal_entry, &prologue_info);

  Fragment body;
  if (!function.is_native()) {
    body += CheckStackOverflowInPrologue(function.token_pos());
  }

  ASSERT(parsed_function_->scope()->num_context_variables() == 0);

  // Should never build a dynamic invocation forwarder for equality
  // operator.
  ASSERT(function.name() != Symbols::EqualOperator().raw());

  // Even if the caller did not pass argument vector we would still
  // call the target with instantiate-to-bounds type arguments.
  body += BuildDefaultTypeHandling(function);

  // Build argument type checks that complement those that are emitted in the
  // target.
  BuildArgumentTypeChecks(
      TypeChecksToBuild::kCheckNonCovariantTypeParameterBounds, &body, &body,
      nullptr);

  // Push all arguments and invoke the original method.

  intptr_t type_args_len = 0;
  if (function.IsGeneric()) {
    type_args_len = function.NumTypeParameters();
    ASSERT(parsed_function_->function_type_arguments() != nullptr);
    body += LoadLocal(parsed_function_->function_type_arguments());
    body += PushArgument();
  }

  // Push receiver.
  ASSERT(function.NumImplicitParameters() == 1);
  body += LoadLocal(parsed_function_->receiver_var());
  body += PushArgument();

  body += PushExplicitParameters(function);

  const intptr_t argument_count = function.NumParameters();
  const auto& argument_names =
      Array::ZoneHandle(Z, GetOptionalParameterNames(function));

  body += StaticCall(TokenPosition::kNoSource, target, argument_count,
                     argument_names, ICData::kNoRebind, nullptr, type_args_len);

  // Later optimization passes assume that result of a x.[]=(...) call is not
  // used. We must guarantee this invariant because violation will lead to an
  // illegal IL once we replace x.[]=(...) with a sequence that does not
  // actually produce any value. See http://dartbug.com/29135 for more details.
  if (name.raw() == Symbols::AssignIndexToken().raw()) {
    body += Drop();
    body += NullConstant();
  }

  body += Return(TokenPosition::kNoSource);

  instruction_cursor->LinkTo(body.entry);

  // When compiling for OSR, use a depth first search to find the OSR
  // entry and make graph entry jump to it instead of normal entry.
  // Catch entries are always considered reachable, even if they
  // become unreachable after OSR.
  if (IsCompiledForOsr()) {
    graph_entry_->RelinkToOsrEntry(Z, last_used_block_id_ + 1);
  }
  return new (Z) FlowGraph(*parsed_function_, graph_entry_, last_used_block_id_,
                           prologue_info);
}

Fragment FlowGraphBuilder::UnboxTruncate(Representation to) {
  auto* unbox = UnboxInstr::Create(to, Pop(), DeoptId::kNone,
                                   Instruction::kNotSpeculative);
  Push(unbox);
  return Fragment(unbox);
}

Fragment FlowGraphBuilder::Box(Representation from) {
  BoxInstr* box = BoxInstr::Create(from, Pop());
  Push(box);
  return Fragment(box);
}

Fragment FlowGraphBuilder::FfiUnboxedExtend(Representation representation,
                                            const AbstractType& ffi_type) {
  const SmallRepresentation from_representation =
      compiler::ffi::TypeSmallRepresentation(ffi_type);
  if (from_representation == kNoSmallRepresentation) return {};

  auto* extend = new (Z)
      UnboxedWidthExtenderInstr(Pop(), representation, from_representation);
  Push(extend);
  return Fragment(extend);
}

Fragment FlowGraphBuilder::NativeReturn(Representation result) {
  auto* instr = new (Z)
      NativeReturnInstr(TokenPosition::kNoSource, Pop(), result,
                        compiler::ffi::ResultLocation(result), DeoptId::kNone);
  return Fragment(instr);
}

Fragment FlowGraphBuilder::FfiPointerFromAddress(const Type& result_type) {
  LocalVariable* address = MakeTemporary();
  LocalVariable* result = parsed_function_->expression_temp_var();

  Class& result_class = Class::ZoneHandle(Z, result_type.type_class());
  // This class might only be instantiated as a return type of ffi calls.
  result_class.EnsureIsFinalized(thread_);

  TypeArguments& args = TypeArguments::ZoneHandle(Z, result_type.arguments());

  // A kernel transform for FFI in the front-end ensures that type parameters
  // do not appear in the type arguments to a any Pointer classes in an FFI
  // signature.
  ASSERT(args.IsNull() || args.IsInstantiated());
  args = args.Canonicalize();

  Fragment code;
  code += Constant(args);
  code += PushArgument();
  code += AllocateObject(TokenPosition::kNoSource, result_class, 1);
  LocalVariable* pointer = MakeTemporary();
  code += LoadLocal(pointer);
  code += LoadLocal(address);
  code += StoreInstanceField(TokenPosition::kNoSource,
                             Slot::Pointer_c_memory_address(),
                             StoreInstanceFieldInstr::Kind::kInitializing);
  code += StoreLocal(TokenPosition::kNoSource, result);
  code += Drop();  // StoreLocal^
  code += Drop();  // address
  code += LoadLocal(result);

  return code;
}

Fragment FlowGraphBuilder::BitCast(Representation from, Representation to) {
  BitCastInstr* instr = new (Z) BitCastInstr(from, to, Pop());
  Push(instr);
  return Fragment(instr);
}

Fragment FlowGraphBuilder::FfiConvertArgumentToDart(
    const AbstractType& ffi_type,
    const Representation native_representation) {
  Fragment body;
  if (compiler::ffi::NativeTypeIsPointer(ffi_type)) {
    body += Box(kUnboxedFfiIntPtr);
    body += FfiPointerFromAddress(Type::Cast(ffi_type));
  } else if (compiler::ffi::NativeTypeIsVoid(ffi_type)) {
    body += Drop();
    body += NullConstant();
  } else {
    const Representation from_rep = native_representation;
    const Representation to_rep =
        compiler::ffi::TypeRepresentation(ffi_type.type_class_id());
    if (from_rep != to_rep) {
      body += BitCast(from_rep, to_rep);
    } else {
      body += FfiUnboxedExtend(from_rep, ffi_type);
    }
    body += Box(to_rep);
  }
  return body;
}

Fragment FlowGraphBuilder::FfiConvertArgumentToNative(
    const Function& function,
    const AbstractType& ffi_type,
    const Representation native_representation) {
  Fragment body;

  // Check for 'null'.
  body += CheckNullOptimized(TokenPosition::kNoSource,
                             String::ZoneHandle(Z, function.name()));

  if (compiler::ffi::NativeTypeIsPointer(ffi_type)) {
    body += LoadNativeField(Slot::Pointer_c_memory_address());
    body += UnboxTruncate(kUnboxedFfiIntPtr);
  } else {
    Representation from_rep =
        compiler::ffi::TypeRepresentation(ffi_type.type_class_id());
    body += UnboxTruncate(from_rep);

    Representation to_rep = native_representation;
    if (from_rep != to_rep) {
      body += BitCast(from_rep, to_rep);
    } else {
      body += FfiUnboxedExtend(from_rep, ffi_type);
    }
  }
  return body;
}

FlowGraph* FlowGraphBuilder::BuildGraphOfFfiTrampoline(
    const Function& function) {
  if (function.FfiCallbackTarget() != Function::null()) {
    return BuildGraphOfFfiCallback(function);
  } else {
    return BuildGraphOfFfiNative(function);
  }
}

FlowGraph* FlowGraphBuilder::BuildGraphOfFfiNative(const Function& function) {
  graph_entry_ =
      new (Z) GraphEntryInstr(*parsed_function_, Compiler::kNoOSRDeoptId);

  auto normal_entry = BuildFunctionEntry(graph_entry_);
  graph_entry_->set_normal_entry(normal_entry);

  PrologueInfo prologue_info(-1, -1);

  BlockEntryInstr* instruction_cursor =
      BuildPrologue(normal_entry, &prologue_info);

  Fragment body(instruction_cursor);
  body += CheckStackOverflowInPrologue(function.token_pos());

  const Function& signature = Function::ZoneHandle(Z, function.FfiCSignature());
  const auto& arg_reps = *compiler::ffi::ArgumentRepresentations(signature);
  const ZoneGrowableArray<HostLocation>* arg_host_locs = nullptr;
  const auto& arg_locs = *compiler::ffi::ArgumentLocations(arg_reps);

  BuildArgumentTypeChecks(TypeChecksToBuild::kCheckAllTypeParameterBounds,
                          &body, &body, &body);

  // Unbox and push the arguments.
  AbstractType& ffi_type = AbstractType::Handle(Z);
  for (intptr_t pos = 1; pos < function.num_fixed_parameters(); pos++) {
    body += LoadLocal(parsed_function_->ParameterVariable(pos));
    ffi_type = signature.ParameterTypeAt(pos);
    body += FfiConvertArgumentToNative(function, ffi_type, arg_reps[pos - 1]);
  }

  // Push the function pointer, which is stored (boxed) in the first slot of the
  // context.
  body += LoadLocal(parsed_function_->ParameterVariable(0));
  body += LoadNativeField(Slot::Closure_context());
  body += LoadNativeField(Slot::GetContextVariableSlotFor(
      thread_, *MakeImplicitClosureScope(
                    Z, Class::Handle(I->object_store()->ffi_pointer_class()))
                    ->context_variables()[0]));
  body += UnboxTruncate(kUnboxedFfiIntPtr);
  body += FfiCall(signature, arg_reps, arg_locs, arg_host_locs);

  ffi_type = signature.result_type();
  const Representation from_rep =
      compiler::ffi::ResultRepresentation(signature);
  body += FfiConvertArgumentToDart(ffi_type, from_rep);
  body += Return(TokenPosition::kNoSource);

  return new (Z) FlowGraph(*parsed_function_, graph_entry_, last_used_block_id_,
                           prologue_info);
}

FlowGraph* FlowGraphBuilder::BuildGraphOfFfiCallback(const Function& function) {
  const Function& signature = Function::ZoneHandle(Z, function.FfiCSignature());
  const auto& arg_reps = *compiler::ffi::ArgumentRepresentations(signature);
  const auto& arg_locs = *compiler::ffi::ArgumentLocations(arg_reps);
  const auto& callback_locs =
      *compiler::ffi::CallbackArgumentTranslator::TranslateArgumentLocations(
          arg_locs);

  graph_entry_ =
      new (Z) GraphEntryInstr(*parsed_function_, Compiler::kNoOSRDeoptId);

  auto* const native_entry = new (Z) NativeEntryInstr(
      &arg_locs, graph_entry_, AllocateBlockId(), CurrentTryIndex(),
      GetNextDeoptId(), function.FfiCallbackId());

  graph_entry_->set_normal_entry(native_entry);

  Fragment function_body(native_entry);
  function_body += CheckStackOverflowInPrologue(function.token_pos());

  // Wrap the entire method in a big try/catch. This is important to ensure that
  // the VM does not crash if the callback throws an exception.
  const intptr_t try_handler_index = AllocateTryIndex();
  Fragment body = TryCatch(try_handler_index);
  ++try_depth_;

  // Box and push the arguments.
  AbstractType& ffi_type = AbstractType::Handle(Z);
  for (intptr_t i = 0, n = callback_locs.length(); i < n; ++i) {
    ffi_type = signature.ParameterTypeAt(i + 1);
    auto* parameter =
        new (Z) NativeParameterInstr(callback_locs[i], arg_reps[i]);
    Push(parameter);
    body <<= parameter;
    body += FfiConvertArgumentToDart(ffi_type, arg_reps[i]);
    body += PushArgument();
  }

  // Call the target.
  //
  // TODO(36748): Determine the hot-reload semantics of callbacks and update the
  // rebind-rule accordingly.
  body += StaticCall(TokenPosition::kNoSource,
                     Function::ZoneHandle(Z, function.FfiCallbackTarget()),
                     callback_locs.length(), Array::empty_array(),
                     ICData::kNoRebind);

  ffi_type = signature.result_type();
  const Representation result_rep =
      compiler::ffi::ResultRepresentation(signature);
  body += FfiConvertArgumentToNative(function, ffi_type, result_rep);
  body += NativeReturn(result_rep);

  --try_depth_;
  function_body += body;

  ++catch_depth_;
  Fragment catch_body =
      CatchBlockEntry(Array::empty_array(), try_handler_index,
                      /*needs_stacktrace=*/false, /*is_synthesized=*/true);

  // Return the "exceptional return" value given in 'fromFunction'.
  //
  // For pointer and void return types, the exceptional return is always null --
  // return 0 instead.
  if (compiler::ffi::NativeTypeIsPointer(ffi_type) ||
      compiler::ffi::NativeTypeIsVoid(ffi_type)) {
    ASSERT(function.FfiCallbackExceptionalReturn() == Object::null());
    catch_body += IntConstant(0);
    catch_body += UnboxTruncate(kUnboxedFfiIntPtr);
  } else {
    catch_body += Constant(
        Instance::ZoneHandle(Z, function.FfiCallbackExceptionalReturn()));
    catch_body += FfiConvertArgumentToNative(function, ffi_type, result_rep);
  }

  catch_body += NativeReturn(result_rep);
  --catch_depth_;

  PrologueInfo prologue_info(-1, -1);
  return new (Z) FlowGraph(*parsed_function_, graph_entry_, last_used_block_id_,
                           prologue_info);
}

void FlowGraphBuilder::SetCurrentTryCatchBlock(TryCatchBlock* try_catch_block) {
  try_catch_block_ = try_catch_block;
  SetCurrentTryIndex(try_catch_block == nullptr ? kInvalidTryIndex
                                                : try_catch_block->try_index());
}

}  // namespace kernel
}  // namespace dart

#endif  // !defined(DART_PRECOMPILED_RUNTIME)
