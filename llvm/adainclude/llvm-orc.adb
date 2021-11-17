pragma Style_Checks (Off);
pragma Warnings (Off, "*is already use-visible*");
pragma Warnings (Off, "*redundant with clause in body*");

with Interfaces.C;         use Interfaces.C;
pragma Unreferenced (Interfaces.C);
with Interfaces.C.Strings; use Interfaces.C.Strings;pragma Unreferenced (Interfaces.C.Strings);

package body LLVM.Orc is

   function Orc_Execution_Session_Intern
     (ES   : Orc_Execution_Session_T;
      Name : String)
      return Orc_Symbol_String_Pool_Entry_T
   is
      Name_Array  : aliased char_array := To_C (Name);
      Name_String : constant chars_ptr := To_Chars_Ptr (Name_Array'Unchecked_Access);
   begin
      return Orc_Execution_Session_Intern_C (ES, Name_String);
   end Orc_Execution_Session_Intern;

   function Orc_Symbol_String_Pool_Entry_Str
     (S : Orc_Symbol_String_Pool_Entry_T)
      return String
   is
   begin
      return Value (Orc_Symbol_String_Pool_Entry_Str_C (S));
   end Orc_Symbol_String_Pool_Entry_Str;

   function Orc_Create_Custom_Materialization_Unit
     (Name        : String;
      Ctx         : System.Address;
      Syms        : Orc_C_Symbol_Flags_Map_Pairs_T;
      Num_Syms    : stddef_h.size_t;
      Init_Sym    : Orc_Symbol_String_Pool_Entry_T;
      Materialize : Orc_Materialization_Unit_Materialize_Function_T;
      Discard     : Orc_Materialization_Unit_Discard_Function_T;
      Destroy     : Orc_Materialization_Unit_Destroy_Function_T)
      return Orc_Materialization_Unit_T
   is
      Name_Array  : aliased char_array := To_C (Name);
      Name_String : constant chars_ptr := To_Chars_Ptr (Name_Array'Unchecked_Access);
   begin
      return Orc_Create_Custom_Materialization_Unit_C (Name_String, Ctx, Syms, Num_Syms, Init_Sym, Materialize, Discard, Destroy);
   end Orc_Create_Custom_Materialization_Unit;

   function Orc_Execution_Session_Create_Bare_JIT_Dylib
     (ES   : Orc_Execution_Session_T;
      Name : String)
      return Orc_JIT_Dylib_T
   is
      Name_Array  : aliased char_array := To_C (Name);
      Name_String : constant chars_ptr := To_Chars_Ptr (Name_Array'Unchecked_Access);
   begin
      return Orc_Execution_Session_Create_Bare_JIT_Dylib_C (ES, Name_String);
   end Orc_Execution_Session_Create_Bare_JIT_Dylib;

   function Orc_Execution_Session_Create_JIT_Dylib
     (ES     : Orc_Execution_Session_T;
      Result : System.Address;
      Name   : String)
      return LLVM.Error.Error_T
   is
      Name_Array  : aliased char_array := To_C (Name);
      Name_String : constant chars_ptr := To_Chars_Ptr (Name_Array'Unchecked_Access);
   begin
      return Orc_Execution_Session_Create_JIT_Dylib_C (ES, Result, Name_String);
   end Orc_Execution_Session_Create_JIT_Dylib;

   function Orc_Execution_Session_Get_JIT_Dylib_By_Name
     (ES   : Orc_Execution_Session_T;
      Name : String)
      return Orc_JIT_Dylib_T
   is
      Name_Array  : aliased char_array := To_C (Name);
      Name_String : constant chars_ptr := To_Chars_Ptr (Name_Array'Unchecked_Access);
   begin
      return Orc_Execution_Session_Get_JIT_Dylib_By_Name_C (ES, Name_String);
   end Orc_Execution_Session_Get_JIT_Dylib_By_Name;

   function Orc_JIT_Target_Machine_Get_Target_Triple
     (JTMB : Orc_JIT_Target_Machine_Builder_T)
      return String
   is
   begin
      return Value (Orc_JIT_Target_Machine_Builder_Get_Target_Triple_C (JTMB));
   end Orc_JIT_Target_Machine_Get_Target_Triple;

   procedure Orc_JIT_Target_Machine_Set_Target_Triple
     (JTMB          : Orc_JIT_Target_Machine_Builder_T;
      Target_Triple : String)
   is
      Target_Triple_Array  : aliased char_array := To_C (Target_Triple);
      Target_Triple_String : constant chars_ptr := To_Chars_Ptr (Target_Triple_Array'Unchecked_Access);
   begin
      Orc_JIT_Target_Machine_Builder_Set_Target_Triple_C (JTMB, Target_Triple_String);
   end Orc_JIT_Target_Machine_Set_Target_Triple;

   function Orc_Create_Local_Indirect_Stubs_Manager
     (Target_Triple : String)
      return Orc_Indirect_Stubs_Manager_T
   is
      Target_Triple_Array  : aliased char_array := To_C (Target_Triple);
      Target_Triple_String : constant chars_ptr := To_Chars_Ptr (Target_Triple_Array'Unchecked_Access);
   begin
      return Orc_Create_Local_Indirect_Stubs_Manager_C (Target_Triple_String);
   end Orc_Create_Local_Indirect_Stubs_Manager;

   function Orc_Create_Local_Lazy_Call_Through_Manager
     (Target_Triple      : String;
      ES                 : Orc_Execution_Session_T;
      Error_Handler_Addr : Orc_JIT_Target_Address_T;
      LCTM               : System.Address)
      return LLVM.Error.Error_T
   is
      Target_Triple_Array  : aliased char_array := To_C (Target_Triple);
      Target_Triple_String : constant chars_ptr := To_Chars_Ptr (Target_Triple_Array'Unchecked_Access);
   begin
      return Orc_Create_Local_Lazy_Call_Through_Manager_C (Target_Triple_String, ES, Error_Handler_Addr, LCTM);
   end Orc_Create_Local_Lazy_Call_Through_Manager;

   function Orc_Create_Dump_Objects
     (Dump_Dir            : String;
      Identifier_Override : String)
      return Orc_Dump_Objects_T
   is
      Dump_Dir_Array             : aliased char_array := To_C (Dump_Dir);
      Dump_Dir_String            : constant chars_ptr := To_Chars_Ptr (Dump_Dir_Array'Unchecked_Access);
      Identifier_Override_Array  : aliased char_array := To_C (Identifier_Override);
      Identifier_Override_String : constant chars_ptr := To_Chars_Ptr (Identifier_Override_Array'Unchecked_Access);
   begin
      return Orc_Create_Dump_Objects_C (Dump_Dir_String, Identifier_Override_String);
   end Orc_Create_Dump_Objects;

end LLVM.Orc;
