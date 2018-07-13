------------------------------------------------------------------------------
--                             G N A T - L L V M                            --
--                                                                          --
--                     Copyright (C) 2013-2018, AdaCore                     --
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

with Ada.Command_Line; use Ada.Command_Line;
with Ada.Directories;

with LLVM.Analysis;   use LLVM.Analysis;
with LLVM.Bit_Writer; use LLVM.Bit_Writer;
with LLVM.Core;       use LLVM.Core;
with LLVM.Debug_Info; use LLVM.Debug_Info;
with LLVM.Support;    use LLVM.Support;

with Errout;   use Errout;
with Lib;      use Lib;
with Opt;      use Opt;
with Osint.C;  use Osint.C;
with Output;   use Output;
with Switch;   use Switch;

with GNATLLVM.Wrapper; use GNATLLVM.Wrapper;

package body GNATLLVM.Codegen is

   function Output_File_Name (Extension : String) return String;
   --  Return the name of the output file, using the given Extension

   -----------------------
   -- Scan_Command_Line --
   -----------------------

   procedure Scan_Command_Line is
   begin
      --  Scan command line for relevant switches and initialize LLVM
      --  target.

      for J in 1 .. Argument_Count loop
         declare
            Switch : constant String := Argument (J);

         begin
            pragma Assert (Switch'First = 1);

            if Switch'Length > 0
              and then Switch (1) /= '-'
            then
               if Is_Regular_File (Switch) then
                  Free (Filename);
                  Filename := new String'(Switch);
               end if;

            elsif Switch = "--dump-ir" then
               Code_Generation := Dump_IR;
            elsif Switch = "--dump-bc" or else Switch = "--write-bc" then
               Code_Generation := Write_BC;
            elsif Switch = "-emit-llvm" then
               Emit_LLVM := True;
            elsif Switch = "-S" then
               Output_Assembly := True;
            elsif Switch = "-g" then
               Emit_Debug_Info := True;
            elsif Switch = "-fstack-check" then
               Do_Stack_Check := True;
            elsif Switch'Length > 9
              and then Switch (1 .. 9) = "--target="
            then
               Free (Target_Triple);
               Target_Triple :=
                 new String'(Switch (10 .. Switch'Last));
            elsif Switch'Length > 6 and then Switch (1 .. 6) = "-mcpu=" then
               Free (CPU);
               CPU := new String'(Switch (7 .. Switch'Last));
            elsif Switch'Length > 1
              and then Switch (1 .. 2) = "-O"
            then
               if Switch'Length = 2 then
                  Code_Gen_Level := Code_Gen_Level_Less;
               else
                  case Switch (3) is
                     when '1' =>
                        Code_Gen_Level := Code_Gen_Level_Less;
                     when '2' | 's' =>
                        Code_Gen_Level := Code_Gen_Level_Default;
                     when '3' =>
                        Code_Gen_Level := Code_Gen_Level_Aggressive;
                     when others =>
                        Code_Gen_Level := Code_Gen_Level_None;
                  end case;
               end if;

            elsif Switch'Length > 6
              and then Switch (1 .. 6) = "-llvm-"
            then
               Switch_Table.Append (new String'(Switch (6 .. Switch'Last)));
            end if;
         end;
      end loop;
   end Scan_Command_Line;

   ----------------------------
   -- Initialize_LLVM_Target --
   ----------------------------

   procedure Initialize_LLVM_Target is
      Num_Builtin : constant := 2;

      type    Addr_Arr     is array (Interfaces.C.int range <>) of Address;
      subtype Switch_Addrs is Addr_Arr (1 .. Switch_Table.Last + Num_Builtin);

      Opt0        : constant String   := "filename" & ASCII.NUL;
      Opt1        : constant String   := "-enable-shrink-wrap=0" & ASCII.NUL;
      Addrs       : Switch_Addrs      :=
        (1 => Opt0'Address, 2 => Opt1'Address, others => <>);
      Ptr_Err_Msg : aliased Ptr_Err_Msg_Type;

   begin
      --  Add any LLVM parameters to the list of switches

      for J in 1 .. Switch_Table.Last loop
         Addrs (J + Num_Builtin) := Switch_Table.Table (J).all'Address;
      end loop;

      Parse_Command_Line_Options (Switch_Table.Last + Num_Builtin,
                                  Addrs'Address, "");

      --  Finalize our compilation mode now that all switches are parsed

      if Emit_LLVM then
         Code_Generation := (if Output_Assembly then Write_IR else Write_BC);
      elsif Output_Assembly then
         Code_Generation := Write_Assembly;
      end if;

      --  Initialize the translation environment

      Initialize_LLVM;
      Context    := Get_Global_Context;
      IR_Builder := Create_Builder_In_Context (Context);
      MD_Builder := Create_MDBuilder_In_Context (Context);
      Module     := Module_Create_With_Name_In_Context (Filename.all, Context);

      if Get_Target_From_Triple
        (Target_Triple.all, LLVM_Target'Address, Ptr_Err_Msg'Address)
      then
         Write_Str
           ("cannot set target to " & Target_Triple.all & ": " &
            Get_LLVM_Error_Msg (Ptr_Err_Msg));
         Write_Eol;
         OS_Exit (4);
      end if;

      Target_Machine    :=
        Create_Target_Machine (T          => LLVM_Target,
                               Triple     => Target_Triple.all,
                               CPU        => CPU.all,
                               Features   => "",
                               Level      => Code_Gen_Level,
                               Reloc      => Reloc_Default,
                               Code_Model => Code_Model_Default);

      Module_Data_Layout := Create_Target_Data_Layout (Target_Machine);
      TBAA_Root          := Create_TBAA_Root (MD_Builder);
      Set_Target (Module, Target_Triple.all);
   end Initialize_LLVM_Target;

   ------------------------
   -- LLVM_Generate_Code --
   ------------------------

   procedure LLVM_Generate_Code (GNAT_Root : Node_Id) is
      Err_Msg : aliased Ptr_Err_Msg_Type;

   begin
      --  Complete and verify the translation.  Unless just writing IR,
      --  suppress doing anything else if there's an error.

      if Verify_Module (Module, Print_Message_Action, Null_Address) then
         Error_Msg_N ("the backend generated bad LLVM code", GNAT_Root);
         if Code_Generation not in Dump_IR | Write_IR then
            Code_Generation := None;
         end if;
      end if;

      --  Output the translation

      case Code_Generation is
         when Dump_IR =>
            Dump_Module (Module);

         when Write_BC =>
            declare
               S : constant String := Output_File_Name (".bc");
            begin
               if Integer (Write_Bitcode_To_File (Module, S)) /= 0 then
                  Error_Msg_N ("could not write `" & S & "`", GNAT_Root);
               end if;
            end;

         when Write_IR =>
            declare
               S : constant String := Output_File_Name (".ll");

            begin
               if Print_Module_To_File (Module, S, Err_Msg'Address) then
                  Error_Msg_N
                    ("could not write `" & S & "`: " &
                       Get_LLVM_Error_Msg (Err_Msg),
                     GNAT_Root);
               end if;
            end;

         when Write_Assembly =>
            declare
               S : constant String := Output_File_Name (".s");
            begin
               if Target_Machine_Emit_To_File
                 (Target_Machine, Module, S, Assembly_File, Err_Msg'Address)
               then
                  Error_Msg_N
                    ("could not write `" & S & "`: " &
                       Get_LLVM_Error_Msg (Err_Msg), GNAT_Root);
               end if;
            end;

         when Write_Object =>
            declare
               S : constant String := Output_File_Name (".o");
            begin
               if Target_Machine_Emit_To_File
                 (Target_Machine, Module, S, Object_File, Err_Msg'Address)
               then
                  Error_Msg_N
                    ("could not write `" & S & "`: " &
                       Get_LLVM_Error_Msg (Err_Msg), GNAT_Root);
               end if;
            end;

         when None =>
            null;
      end case;

      --  Release the environment

      Dispose_DI_Builder (DI_Builder);
      Dispose_Builder (IR_Builder);
      Dispose_Module  (Module);
   end LLVM_Generate_Code;

   ------------------------
   -- Is_Back_End_Switch --
   ------------------------

   function Is_Back_End_Switch (Switch : String) return Boolean is
      First : constant Positive := Switch'First + 1;
      Last  : constant Natural  := Switch_Last (Switch);

   begin
      if not Is_Switch (Switch) then
         return False;
      elsif Switch = "--dump-ir" then
         return True;
      elsif Switch = "--dump-bc" or else Switch = "--write-bc" then
         return True;
      elsif Switch = "-emit-llvm" then
         return True;
      elsif Switch = "-S" then
         return True;
      elsif Switch = "-g" then
         return True;
      elsif Switch = "-fstack-check" then
         return True;
      elsif Last > First + 7
        and then Switch (First .. First + 7) = "-target="
      then
         return True;
      elsif Last > First + 4
        and then Switch (First .. First + 4) = "llvm-"
      then
         return True;
      end if;

      --  For now we allow the -f/-m/-W/-w and -pipe switches, even
      --  though they will have no effect.
      --  This permits compatibility with existing scripts.

      return Switch (First) in 'f' | 'm' | 'W' | 'w'
        or else Switch (First .. Last) = "pipe";
   end Is_Back_End_Switch;

   ----------------------
   -- Output_File_Name --
   ----------------------

   function Output_File_Name (Extension : String) return String is
   begin
      if not Output_File_Name_Present then
         return
           Ada.Directories.Base_Name
             (Get_Name_String (Name_Id (Unit_File_Name (Main_Unit))))
           & Extension;

      --  The Output file name was specified in the -o argument

      else
         --  Locate the last dot to remove the extension of native platforms
         --  (for example, file.o).

         declare
            S : constant String := Get_Output_Object_File_Name;
         begin
            for J in reverse S'Range loop
               if S (J) = '.' then
                  return S (S'First .. J - 1) & Extension;
               end if;
            end loop;

            return S & Extension;
         end;
      end if;
   end Output_File_Name;

end GNATLLVM.Codegen;