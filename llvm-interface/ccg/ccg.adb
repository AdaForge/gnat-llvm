------------------------------------------------------------------------------
--                              C C G                                       --
--                                                                          --
--                     Copyright (C) 2020-2023, AdaCore                     --
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

with Atree;       use Atree;
with Einfo.Utils; use Einfo.Utils;
with Sem_Aux;     use Sem_Aux;
with Stand;       use Stand;
with Sinput;      use Sinput;

with GNATLLVM.Codegen; use GNATLLVM.Codegen;
with GNATLLVM.Wrapper; use GNATLLVM.Wrapper;

with CCG.Codegen;      use CCG.Codegen;
with CCG.Environment;  use CCG.Environment;
with CCG.Instructions; use CCG.Instructions;
with CCG.Subprograms;  use CCG.Subprograms;
with CCG.Target;       use CCG.Target;
with CCG.Utils;        use CCG.Utils;

package body CCG is

   --  This package and its children generate C code from the LLVM IR
   --  generated by GNAT LLVM.

   -------------------------
   -- C_Initialize_Output --
   -------------------------

   procedure C_Initialize_Output renames Initialize_Output;

   ----------------
   -- C_Generate --
   ----------------

   procedure C_Generate (Module : Module_T) renames Generate;

   ---------------------------
   -- C_Add_To_Source_Order --
   ---------------------------

   procedure C_Add_To_Source_Order (N : Node_Id) is
   begin
      --  If we're emitting C, add the item to the source order list and
      --  record the lowest line number we've seen.

      if Emit_C and then not Emit_Header then
         Add_To_Source_Order (N);
         if Get_Source_File_Index (Sloc (N)) = Main_Source_File
           and then (Get_Physical_Line_Number (Sloc (N)) < Lowest_Line_Number
                     or else Lowest_Line_Number = Physical_Line_Number'First)
         then
            Lowest_Line_Number := Get_Physical_Line_Number (Sloc (N));
         end if;
      end if;
   end C_Add_To_Source_Order;

   ----------------------------
   -- C_Protect_Source_Order --
   ----------------------------

   procedure C_Protect_Source_Order renames Protect_Source_Order;

   ----------------------
   -- C_Set_Field_Info --
   ----------------------

   procedure C_Set_Field_Info
     (UID         : Unique_Id;
      Idx         : Nat;
      Name        : Name_Id   := No_Name;
      Entity      : Entity_Id := Types.Empty;
      Is_Padding  : Boolean   := False;
      Is_Bitfield : Boolean   := False) is
   begin
      if Emit_C then
         Set_Field_C_Info (UID, Idx, Name, Entity, Is_Padding, Is_Bitfield);
      end if;
   end C_Set_Field_Info;

   ------------------
   -- C_Set_Struct --
   ------------------

   procedure C_Set_Struct (UID : Unique_Id; T : Type_T) is
   begin
      if Emit_C then
         Set_Struct (UID, T);
      end if;
   end C_Set_Struct;

   ---------------------
   -- C_Set_Parameter --
   ---------------------

   procedure C_Set_Parameter
     (UID : Unique_Id; Idx : Nat; Entity : Entity_Id) is
   begin
      if Emit_C then
         Set_Parameter (UID, Idx, Entity);
      end if;
   end C_Set_Parameter;

   --------------------
   -- C_Set_Function --
   --------------------

   procedure C_Set_Function (UID : Unique_Id; V : Value_T) is
   begin
      if Emit_C then
         Set_Function (UID, V);
      end if;
   end C_Set_Function;

   ------------------
   -- C_Set_Entity --
   ------------------

   procedure C_Set_Entity
     (V : Value_T; E : Entity_Id; Reference : Boolean := False)
   is
      Prev_E : constant Entity_Id := Get_Entity (V);

   begin
      --  If we're not emitting C, we don't need to do anything

      if not Emit_C then
         return;

      --  We only want to set this the first time because that will be the
      --  most reliable information. However, we prefer an entity over a type.

      elsif (Present (Prev_E) and then not Is_Type (E)
             and then Is_Type (Prev_E))
        or else No (Prev_E)
      then
         Notify_On_Value_Delete (V, Delete_Value_Info'Access);
         Set_Entity             (V, E);
         Set_Entity_Is_Ref      (V, Reference);
      end if;
   end C_Set_Entity;

   ------------------
   -- C_Set_Entity --
   ------------------

   procedure C_Set_Entity (T : Type_T; TE : Type_Kind_Id)
   is
   begin
      if Emit_C then
         Set_Entity (T, TE);
      end if;
   end C_Set_Entity;

   ------------------------------
   -- C_Dont_Add_Inline_Always --
   ------------------------------

   function C_Dont_Add_Inline_Always return Boolean is
     (Emit_C and then Inline_Always_Must);

   ---------------------
   -- C_Address_Taken --
   ---------------------

   procedure C_Address_Taken (V : Value_T) is
   begin
      if Emit_C then
         Set_Needs_Nest (V);
      end if;
   end C_Address_Taken;

   ---------------------
   -- C_Set_Elab_Proc --
   ---------------------

   procedure C_Set_Elab_Proc (V : Value_T; For_Body : Boolean) is
   begin
      if For_Body then
         Elab_Body_Func := V;
      else
         Elab_Spec_Func := V;
      end if;
   end C_Set_Elab_Proc;

   -----------------
   -- C_Note_Enum --
   -----------------

   procedure C_Note_Enum (TE : E_Enumeration_Type_Id) is
      E : Entity_Id := First_Entity (Scope (TE));

   begin
      --  We only do something if we're emitting a header file, this type
      --  is public, and it's not in a dynamic scope.

      if not Emit_Header or else not Is_Public (TE)
        or else Enclosing_Dynamic_Scope (TE) /= Standard_Standard
      then
         return;
      end if;

      --  If this type is in the entity chain of its scope, it means that
      --  it's a package spec, so make a note of it. But if we've passed the
      --  first private entity, it's in the private part, so don't include it.

      while Present (E) loop
         if E = First_Private_Entity (Scope (TE)) then
            return;
         elsif E = TE then
            Note_Enum (TE);
         end if;

         E := Next_Entity (E);
      end loop;
   end C_Note_Enum;

   -------------------------
   -- C_Create_Annotation --
   -------------------------

   function C_Create_Annotation (N : N_Pragma_Id) return Nat
     renames Create_Annotation;

   ----------------------
   -- C_Process_Switch --
   ----------------------

   function C_Process_Switch (Switch : String) return Boolean
     renames Process_Switch;

   -----------------
   -- C_Is_Switch --
   -----------------

   function C_Is_Switch (Switch : String) return Boolean renames Is_Switch;

   ------------------------
   -- C_Can_Cross_Inline --
   ------------------------

   function C_Can_Cross_Inline return Boolean is
     (Emit_C and then C_Version >= 1999);

end CCG;
