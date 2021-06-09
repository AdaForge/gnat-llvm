------------------------------------------------------------------------------
--                              C C G                                       --
--                                                                          --
--                     Copyright (C) 2020-2021, AdaCore                     --
--                                                                          --
-- This is free software;  you can redistribute it  and/or modify it  under --
-- terms of the  GNU General Public License as published  by the Free Soft- --
-- ware  Foundation;  either version 3,  or (at your option) any later ver- --
-- sion.  This software is distributed in the hope  that it will be useful, --
-- but WITHOUT ANY WARRANTY;  without even the implied warranty of MERCHAN- --
-- TABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public --
-- License for  more details.  You should have  received  a copy of the GNU --
-- General  Public  License  distributed  with  this  software;   see  file --
-- COPYING3.  If not, go to http://www.gnu.org/licenses for a complete copy --
-- of the license.                                                          --
------------------------------------------------------------------------------

with LLVM.Core; use LLVM.Core;

with Errout;   use Errout;
with Get_Targ; use Get_Targ;
with Opt;      use Opt;
with Output;   use Output;

with GNATLLVM.Codegen; use GNATLLVM.Codegen;
with GNATLLVM.Wrapper; use GNATLLVM.Wrapper;

with CCG.Aggregates;  use CCG.Aggregates;
with CCG.Environment; use CCG.Environment;
with CCG.Helper;      use CCG.Helper;
with CCG.Output;      use CCG.Output;
with CCG.Subprograms; use CCG.Subprograms;

package body CCG is

   --  This package and its children generate C code from the LLVM IR
   --  generated by GNAT LLLVM.

   --------------------------
   --  Initialize_C_Output --
   --------------------------

   procedure Initialize_C_Output is
   begin
      --  Initialize the sizes of integer types.

      Char_Size      := Get_Char_Size;
      Short_Size     := Get_Short_Size;
      Int_Size       := Get_Int_Size;
      Long_Size      := Get_Long_Size;
      Long_Long_Size := Get_Long_Long_Size;

      --  When emitting C, we don't want to write variable-specific debug
      --  info, just line number information. But we do want to write #line
      --  info if -g was specified and need to turn on minimal debugging if
      --  -gnatL was specified.

      Emit_Full_Debug_Info := False;
      Emit_C_Line          := Emit_Debug_Info;
      Emit_Debug_Info      := Emit_Debug_Info or Dump_Source_Text;
   end Initialize_C_Output;

   ------------------
   -- Write_C_Code --
   ------------------

   procedure Write_C_Code (Module : Module_T) is
      Func : Value_T;
      Glob : Value_T;

   begin
      Initialize_Writing;

      --  Declare all functions first, since they may be referenced in
      --  globals.

      Func := Get_First_Function (Module);
      while Present (Func) loop
         Declare_Subprogram (Func);
         Func := Get_Next_Function (Func);
      end loop;

      --  Write out declarations for all globals with initializers

      Glob := Get_First_Global (Module);
      while Present (Glob) loop
         if Present (Get_Initializer (Glob)) then
            Maybe_Decl (Glob);
         end if;

         Glob := Get_Next_Global (Glob);
      end loop;

      --  Process all functions, writing globals and typedefs on the fly
      --  and queueing the rest for later output.

      Func := Get_First_Function (Module);
      while Present (Func) loop
         Output_Subprogram (Func);
         Func := Get_Next_Function (Func);
      end loop;

      --  Finally, write all the code we generated and finalize the writing
      --  process.

      Write_Subprograms;
      Finalize_Writing;
   end Write_C_Code;

   ---------------------------
   -- C_Set_Field_Name_Info --
   ---------------------------

   procedure C_Set_Field_Name_Info
     (SID         : Struct_Id;
      Idx         : Nat;
      Name        : Name_Id := No_Name;
      Is_Padding  : Boolean := False;
      Is_Bitfield : Boolean := False) is
   begin
      if Emit_C then
         Set_Field_Name_Info (SID, Idx, Name, Is_Padding, Is_Bitfield);
      end if;
   end C_Set_Field_Name_Info;

   ------------------
   -- C_Set_Struct --
   ------------------

   procedure C_Set_Struct (SID : Struct_Id; T : Type_T) is
   begin
      if Emit_C then
         Set_Struct (SID, T);
      end if;
   end C_Set_Struct;

   -----------------------
   -- C_Set_Is_Unsigned --
   -----------------------

   procedure C_Set_Is_Unsigned (V : Value_T) is
   begin
      if Emit_C then
         Set_Is_Unsigned (V);
         Notify_On_Value_Delete (V, Delete_Value_Info'Access);
      end if;
   end C_Set_Is_Unsigned;

   -----------------------
   -- C_Set_Is_Variable --
   -----------------------

   procedure C_Set_Is_Variable (V : Value_T) is
   begin
      --  If we're generating LLVM to generate C and this has a name,
      --  show that it's a variable.

      if Emit_C and then Has_Name (V) then
         Set_Is_Variable (V);
         Notify_On_Value_Delete (V, Delete_Value_Info'Access);
      end if;
   end C_Set_Is_Variable;

   ---------------
   -- Error_Msg --
   ---------------

   procedure Error_Msg (Msg : String) is
   begin
      Error_Msg (Msg, First_Source_Ptr);
   end Error_Msg;

   -------------
   -- Discard --
   -------------

   procedure Discard (B : Boolean) is
      pragma Unreferenced (B);

   begin
      null;
   end Discard;

end CCG;
