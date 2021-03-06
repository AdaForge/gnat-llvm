------------------------------------------------------------------------------
--                              C C G                                       --
--                                                                          --
--                     Copyright (C) 2020, AdaCore                          --
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

with Debug;    use Debug;
with Get_Targ; use Get_Targ;
with Osint;    use Osint;
with Osint.C;  use Osint.C;
with Output;   use Output;

with GNATLLVM.Codegen; use GNATLLVM.Codegen;
with GNATLLVM.Wrapper; use GNATLLVM.Wrapper;

with CCG.Aggregates;  use CCG.Aggregates;
with CCG.Tables;      use CCG.Tables;
with CCG.Output;      use CCG.Output;
with CCG.Subprograms; use CCG.Subprograms;

package body CCG is

   --  This package and its children generate C code from the LLVM IR
   --  generated by GNAT LLLVM.

   ---------------------------
   --  Initialize_C_Writing --
   ---------------------------

   procedure Initialize_C_Writing is
   begin
      --  Initialize the sizes of integer types.

      Char_Size      := Get_Char_Size;
      Short_Size     := Get_Short_Size;
      Int_Size       := Get_Int_Size;
      Long_Size      := Get_Long_Size;
      Long_Long_Size := Get_Long_Long_Size;
   end Initialize_C_Writing;

   ------------------
   -- Write_C_Code --
   ------------------

   procedure Write_C_Code (Module : Module_T) is
      Func : Value_T;
      Glob : Value_T;

   begin
      --  If we're not writing to standard output, open the .c file

      if not Debug_Flag_Dot_YY then
         Namet.Unlock;
         Create_C_File;
         Set_Output (Output_FD);
         Namet.Lock;
      end if;

      Write_Str ("#include <string.h>");
      Write_Eol;
      Write_Str ("#include <stdlib.h>");
      Write_Eol;
      Write_Str ("#include <alloca.h>");
      Write_Eol;
      Write_Eol;

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
         Generate_C_For_Subprogram (Func);
         Func := Get_Next_Function (Func);
      end loop;

      --  Finally, write all the code we generated and close the .c file
      --  if we made one.

      Write_Subprograms;
      if not Debug_Flag_Dot_YY then
         Close_C_File;
         Set_Standard_Output;
      end if;
   end Write_C_Code;

   ---------------------------
   -- C_Set_Field_Name_Info --
   ---------------------------

   procedure C_Set_Field_Name_Info
     (TE          : Entity_Id;
      Idx         : Nat;
      Name        : Name_Id := No_Name;
      Is_Padding  : Boolean := False;
      Is_Bitfield : Boolean := False) is
   begin
      --  If we're not generating C code, don't do anything

      if Code_Generation /= Write_C then
         return;
      end if;

      Set_Field_Name_Info (TE, Idx, Name, Is_Padding, Is_Bitfield);

   end C_Set_Field_Name_Info;

   ------------------
   -- C_Set_Struct --
   ------------------

   procedure C_Set_Struct (TE : Entity_Id; T : Type_T) is
   begin
      if Code_Generation /= Write_C then
         return;
      end if;

      Set_Struct (TE, T);

   end C_Set_Struct;

   -----------------------
   -- C_Set_Is_Unsigned --
   -----------------------

   procedure C_Set_Is_Unsigned (V : Value_T) is
   begin
      if Code_Generation /= Write_C then
         return;
      end if;

      Set_Is_Unsigned (V);
      Notify_On_Value_Delete (V, Delete_Value_Info'Access);
   end C_Set_Is_Unsigned;
end CCG;
