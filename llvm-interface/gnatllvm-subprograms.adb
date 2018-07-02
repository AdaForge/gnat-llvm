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

with Errout;   use Errout;
with Exp_Unst; use Exp_Unst;
with Lib;      use Lib;
with Restrict; use Restrict;
with Sem_Aux;  use Sem_Aux;
with Sem_Mech; use Sem_Mech;
with Sem_Util; use Sem_Util;
with Snames;   use Snames;
with Stand;    use Stand;
with Table;    use Table;

with LLVM.Core; use LLVM.Core;

with GNATLLVM.Blocks;      use GNATLLVM.Blocks;
with GNATLLVM.Compile;     use GNATLLVM.Compile;
with GNATLLVM.Environment; use GNATLLVM.Environment;
with GNATLLVM.Exprs;       use GNATLLVM.Exprs;
with GNATLLVM.DebugInfo;   use GNATLLVM.DebugInfo;
with GNATLLVM.Records;     use GNATLLVM.Records;
with GNATLLVM.Types;       use GNATLLVM.Types;
with GNATLLVM.Variables;   use GNATLLVM.Variables;

package body GNATLLVM.Subprograms is

   --  We define enum types corresponding to information about subprograms
   --  and their parameters that we use consistently within this file to
   --  process those subprograms and parameters.

   type Param_Kind is
     (PK_By_Reference,
      --  This parameter is passed by reference

      Foreign_By_Reference,
      --  Similar to By_Reference, but for a subprogram with foreign convention

      Activation_Record,
      --  This parameter is a pointer to an activation record

      In_Value,
      --  This parameter is passed by value, but used only as an input

      Out_Value,
      --  This parameter is passed by value, but is only an output

      In_Out_Value);
      --  This parameter is passed by value and is both an input and output

   function PK_Is_Reference (PK : Param_Kind) return Boolean is
     (PK in PK_By_Reference | Foreign_By_Reference);
   --  True if this parameter kind represents a value passed by reference

   function PK_Is_In (PK : Param_Kind) return Boolean is
     (PK not in Out_Value);
   --  True if this parameter kind corresponds to an input parameter to
   --  the subprogram.

   function PK_Is_Out (PK : Param_Kind) return Boolean is
     (PK in Out_Value | In_Out_Value);
   --  True if this parameter kind is returned from the subprogram

   function Get_Param_Kind (Param : Entity_Id) return Param_Kind
     with Pre => Ekind_In (Param, E_In_Parameter, E_In_Out_Parameter,
                           E_Out_Parameter);
   --  Return the parameter kind for Param

   function Relationship_For_PK
     (PK : Param_Kind; TE : Entity_Id) return GL_Relationship
     with Pre => Is_Type (TE);
   --  Return the Relationship for a parameter of type TE and kind PK

   function Count_In_Params (E : Entity_Id) return Nat
     with Pre => Ekind (E) in Subprogram_Kind | E_Subprogram_Type;
   --  Return a count of the number of parameters of E, that are
   --  explict input parameters to E.  We may have to add a parameter for
   --  an activation record and/or address to place the return.

   function Count_Out_Params (E : Entity_Id) return Nat
     with Pre => Ekind (E) in Subprogram_Kind | E_Subprogram_Type;
   --  Return a count of the number of parameters of E, that are
   --  output parameters to E.

   function First_Out_Param (E : Entity_Id) return Entity_Id
     with Pre  => Ekind (E) in Subprogram_Kind | E_Subprogram_Type,
          Post => No (First_Out_Param'Result)
                  or else (Ekind_In (First_Out_Param'Result,
                                     E_Out_Parameter, E_In_Out_Parameter));

   function Next_Out_Param (E : Entity_Id) return Entity_Id
     with Pre  => Ekind_In (E, E_Out_Parameter, E_In_Out_Parameter),
          Post => No (Next_Out_Param'Result)
                  or else (Ekind_In (Next_Out_Param'Result,
                                     E_Out_Parameter, E_In_Out_Parameter));

   procedure Next_Out_Param (E : in out Entity_Id)
     with Pre  => Ekind_In (E, E_Out_Parameter, E_In_Out_Parameter),
          Post => No (E) or else (Ekind_In (E, E_Out_Parameter,
                                            E_In_Out_Parameter));

   --  For subprogram return, we have the mechanism for handling the
   --  subprogram return value, if any, and what the actual LLVM function
   --  returns, which is a combination of any return value and any scalar
   --  out parameters.

   type Return_Kind is
     (None,
      --  This is a procedure; there is no return value

      RK_By_Reference,
      --  The result is returned by reference

      Value_Return,
      --  The result is returned by value

      Return_By_Parameter);
      --  The result is returned via a pointer passed as an extra parameter

   function Get_Return_Kind (Def_Ident : Entity_Id) return Return_Kind
     with Pre => Ekind (Def_Ident) in Subprogram_Kind | E_Subprogram_Type;
   --  Get the Return_Kind of Def_Ident, a subprogram or subprogram type

   --  Last, we have the actual LLVM return contents, which can be the
   --  subprogram return, one or more out parameters, or both.  This
   --  says which.

   type L_Ret_Kind is
     (Void,
      --  The LLVM function has no return, meaning this is a procedure
      --  with no out parameters.

      Subprog_Return,
      --  The LLVM function returns what the Ada function returns.
      --  Return_Kind says if its by value or by reference

      Out_Return,
      --  The LLVM function returns the contents of the single out
      --  parameter of a procedure, which must be by value

      Struct_Out,
      --  The LLVM function returns the contents of more than one
      --  out parameter of a procedure, put together into a struct.

      Struct_Out_Subprog);
      --  The LLVM function retuns a struct which contains both the actual
      --  return data of the function (either by value or reference) and
      --  one or more out parameters.

   function Get_L_Ret_Kind (Def_Ident : Entity_Id) return L_Ret_Kind
     with Pre => Ekind (Def_Ident) in Subprogram_Kind | E_Subprogram_Type;

   --  Elaboration entries can be either nodes to be emitted as statements
   --  or expressions to be saved.

   type Elaboration_Entry is record
      N         : Node_Id;
      --  Note to elaborate, possibly as an exppression

      For_Type  : Entity_Id;
      --  If Present, compute N as a value, convert it to this type, and
      --  save the result as the value corresponding to it.
   end record;

   package Elaboration_Table is new Table.Table
     (Table_Component_Type => Elaboration_Entry,
      Table_Index_Type     => Nat,
      Table_Low_Bound      => 1,
      Table_Initial        => 1024,
      Table_Increment      => 100,
      Table_Name           => "Elaboration_Table");
   --  Table of statements part of the current elaboration procedure

   package Nested_Functions_Table is new Table.Table
     (Table_Component_Type => Node_Id,
      Table_Index_Type     => Nat,
      Table_Low_Bound      => 1,
      Table_Initial        => 10,
      Table_Increment      => 5,
      Table_Name           => "Nested_Function_Table");
   --  Table of nested functions to elaborate

   type Intrinsic is record
      Name  : access String;
      Width : Uint;
      Func  : GL_Value;
   end record;
   --  A description of an intrinsic function that we've created

   --  Since we aren't going to be creating all that many different
   --  intrinsic functions, a simple list that we search should be
   --  fast enough.

   package Intrinsic_Functions_Table is new Table.Table
     (Table_Component_Type => Intrinsic,
      Table_Index_Type     => Nat,
      Table_Low_Bound      => 1,
      Table_Initial        => 20,
      Table_Increment      => 5,
      Table_Name           => "Intrinsic_Function_Table");

   Default_Alloc_Fn  : GL_Value := No_GL_Value;
   --  Default memory allocation function

   Default_Free_Fn   : GL_Value := No_GL_Value;
   --  Default memory deallocation function

   Memory_Compare_Fn : GL_Value := No_GL_Value;
   --  Function to compare memory

   Stack_Save_Fn     : GL_Value := No_GL_Value;
   Stack_Restore_Fn  : GL_Value := No_GL_Value;
   --  Functions to save and restore the stack pointer

   Tramp_Init_Fn     : GL_Value := No_GL_Value;
   Tramp_Adjust_Fn   : GL_Value := No_GL_Value;
   --  Functions to initialize and adjust a trampoline

   function Get_Activation_Record_Ptr
     (V : GL_Value; E : Entity_Id) return GL_Value
     with Pre  => Is_Record_Type (Full_Designated_Type (V))
                  and then Ekind (E) = E_Component,
          Post => Is_Record_Type (Full_Designated_Type
                                    (Get_Activation_Record_Ptr'Result));
   --  We need field E from an activation record.  V is the activation record
   --  pointer passed to the current subprogram.  Return a pointer to the
   --  proper activation record, which is either V or an up-level pointer.

   function Name_To_RMW_Op
     (S           : String;
      Index       : Integer;
      End_Index   : out Integer;
      Op          : out Atomic_RMW_Bin_Op_T) return Boolean;
   --  See if the string S starting at position Index is the name of
   --  a supported LLVM atomicrmw instruction.  If so, set End_Index
   --  to after the name and Op to the code for the operation and return True.

   function Emit_Bswap_Call (N : Node_Id; S : String) return GL_Value
     with Pre  => Nkind (N) in N_Subprogram_Call;
   --  If N is a valid call to builtin_bswap, generate it

   function Emit_Sync_Call (N : Node_Id; S : String) return GL_Value
     with Pre  => Nkind (N) in N_Subprogram_Call;
   --  If S is a valid __sync name, emit the LLVM for it and return the
   --  result.  Otherwise, return No_GL_Value.

   function Emit_Intrinsic_Call (N : Node_Id; Subp : Entity_Id) return GL_Value
     with Pre  => Nkind (N) in N_Subprogram_Call;
   --  If Subp is an intrinsic that we know how to handle, emit the LLVM
   --  for it and return the result.  Otherwise, No_GL_Value.

   function Has_Activation_Record (Def_Ident : Entity_Id) return Boolean
     with Pre => Ekind (Def_Ident) in Subprogram_Kind | E_Subprogram_Type;
   --  Return True if Def_Ident is a nested subprogram or a subprogram type
   --  that needs an activation record.

   function Get_Tramp_Init_Fn   return GL_Value;
   function Get_Tramp_Adjust_Fn return GL_Value;

   Ada_Main_Elabb : GL_Value := No_GL_Value;
   --  ???  This a kludge.  We sometimes need an elab proc for Ada_Main and
   --  this can cause confusion with global names.  So if we made it as
   --  part of the processing of a declaration, save it.

   ---------------------
   -- Count_In_Params --
   ---------------------

   function Count_In_Params (E : Entity_Id) return Nat is
      Param : Entity_Id := First_Formal_With_Extras (E);

   begin
      return Cnt : Nat := 0 do
         while Present (Param) loop
            if PK_Is_In (Get_Param_Kind (Param)) then
               Cnt := Cnt + 1;
            end if;

            Next_Formal_With_Extras (Param);
         end loop;
      end return;
   end Count_In_Params;

   ----------------------
   -- Count_Out_Params --
   ----------------------

   function Count_Out_Params (E : Entity_Id) return Nat is
      Param : Entity_Id := First_Formal_With_Extras (E);

   begin
      return Cnt : Nat := 0 do
         while Present (Param) loop
            if PK_Is_Out (Get_Param_Kind (Param)) then
               Cnt := Cnt + 1;
            end if;

            Next_Formal_With_Extras (Param);
         end loop;
      end return;
   end Count_Out_Params;

   ---------------------
   -- First_Out_Param --
   ---------------------

   function First_Out_Param (E : Entity_Id) return Entity_Id is
      Param : Entity_Id := First_Formal_With_Extras (E);

   begin
      while Present (Param) loop
         exit when PK_Is_Out (Get_Param_Kind (Param));
         Next_Formal_With_Extras (Param);
      end loop;

      return Param;
   end First_Out_Param;

   ---------------------
   -- Next_Out_Param --
   ---------------------

   function Next_Out_Param (E : Entity_Id) return Entity_Id is
      Param : Entity_Id := Next_Formal_With_Extras (E);

   begin
      while Present (Param) loop
         exit when PK_Is_Out (Get_Param_Kind (Param));
         Next_Formal_With_Extras (Param);
      end loop;

      return Param;
   end Next_Out_Param;

   ---------------------
   -- Next_Out_Param --
   ---------------------

   procedure Next_Out_Param (E : in out Entity_Id) is
   begin
      E := Next_Out_Param (E);
   end Next_Out_Param;

   --------------------
   -- Get_Param_Kind --
   --------------------

   function Get_Param_Kind (Param : Entity_Id) return Param_Kind is
      TE           : constant Entity_Id  := Full_Etype (Param);
      Param_Mode   : Entity_Kind         := Ekind (Param);
      Ptr_Size     : constant ULL        :=
        Get_LLVM_Type_Size (Void_Ptr_Type);
      By_Copy_Kind : Param_Kind;

      function Has_Initialized_Component (TE : Entity_Id) return Boolean
        with Pre => Is_Record_Type (TE);
      --  Returns True if there's an E_Component in TE that has a
      --  default expression.  See RM 6.4.1(14).

      -------------------------------
      -- Has_Initialized_Component --
      -------------------------------

      function Has_Initialized_Component (TE : Entity_Id) return Boolean is
         F : Entity_Id := First_Entity (Implementation_Base_Type (TE));

      begin
         while Present (F) loop
            exit when Ekind (F) = E_Component and then Present (Parent (F))
              and then Present (Expression (Parent (F)));
            Next_Entity (F);
         end loop;

         return Present (F);
      end Has_Initialized_Component;

   begin
      --  There are some case where an out parameter needs to be
      --  viewed as in out.  These are detailed at 6.4.1(12).

      if Param_Mode = E_Out_Parameter
        and then (Is_Access_Type (TE)
                    or else (Is_Scalar_Type (TE)
                               and then Present (Default_Aspect_Value (TE)))
                    or else Has_Discriminants (TE)
                    or else (Is_Record_Type (TE)
                               and then Has_Initialized_Component (TE)))
      then
         Param_Mode := E_In_Out_Parameter;
      end if;

      --  Set the return value if this ends up being by-copy.

      By_Copy_Kind := (if    Param_Mode = E_In_Parameter     then In_Value
                       elsif Param_Mode = E_In_Out_Parameter then In_Out_Value
                       else  Out_Value);

      --  Handle the easy case of an activation record

      if Param_Mode = E_In_Parameter
        and then Is_Activation_Record (Param)
      then
         return Activation_Record;

      --  For foreign convension, the only time we pass by value is an
      --  elementary type that's an In parameter and the mechanism isn't
      --  By_Reference.

      elsif Has_Foreign_Convention (Param)
        or else Has_Foreign_Convention (Scope (Param))
      then
         return (if   Param_Mode = E_In_Parameter
                        and then Is_Elementary_Type (TE)
                        and then Mechanism (Param) /= By_Reference
                 then In_Value else Foreign_By_Reference);

      --  Force by-reference and dynamic-sized types to be passed by reference

      elsif Is_By_Reference_Type (TE) or else Is_Dynamic_Size (TE) then
         return PK_By_Reference;

      --  If the mechanism is specified, use it

      elsif Mechanism (Param) = By_Reference then
         return PK_By_Reference;

      elsif Mechanism (Param) = By_Copy then
         return By_Copy_Kind;

      --  For the default case, return by reference if it' larger than
      --  two pointer.

      else
         return (if   Get_LLVM_Type_Size (Create_Type (TE)) > 2 * Ptr_Size
                 then PK_By_Reference else By_Copy_Kind);
      end if;

   end Get_Param_Kind;

   ---------------------
   -- Get_Return_Kind --
   ---------------------

   function Get_Return_Kind (Def_Ident : Entity_Id) return Return_Kind is
      TE       : constant Entity_Id := Full_Etype (Def_Ident);
      T        : constant Type_T    :=
        (if Ekind (TE) /= E_Void then Create_Type (TE) else No_Type_T);
      Ptr_Size : constant ULL       :=
        Get_LLVM_Type_Size (Void_Ptr_Type);

   begin
      --  If there's no return type, that's simple

      if Ekind (TE) = E_Void then
         return None;

      --  Otherwise, we return by reference if we're required to

      elsif Returns_By_Ref (Def_Ident) or else Is_By_Reference_Type (TE)
        or else Requires_Transient_Scope (TE)
      then
         return RK_By_Reference;

      --  If this is not an unconstrained array, but is either of dynamic
      --  size or a Convention Ada subprogram with a large return, we
      --  return the value via an extra parameter.

      elsif not Is_Unconstrained_Array (TE)
        and then (Is_Dynamic_Size (TE)
                    or else (not Has_Foreign_Convention (Def_Ident)
                               and then Get_LLVM_Type_Size (T) > 5 * Ptr_Size))
      then
         return Return_By_Parameter;

      --  Otherwise, return by value

      else
         return Value_Return;
      end if;

   end Get_Return_Kind;

   --------------------
   -- Get_L_Ret_Kind --
   --------------------

   function Get_L_Ret_Kind (Def_Ident : Entity_Id) return L_Ret_Kind is
      RK      : constant Return_Kind := Get_Return_Kind (Def_Ident);
      Num_Out : constant Nat         := Count_Out_Params (Def_Ident);
      Has_Ret : constant Boolean     := RK not in None | Return_By_Parameter;

   begin
      if not Has_Ret and then Num_Out = 0 then
         return Void;
      elsif Num_Out = 0 then
         return Subprog_Return;
      elsif not Has_Ret then
         return (if Num_Out = 1 then Out_Return else Struct_Out);
      else
         return Struct_Out_Subprog;
      end if;
   end Get_L_Ret_Kind;

   -------------------------
   -- Relationship_For_PK --
   -------------------------

   function Relationship_For_PK
     (PK : Param_Kind; TE : Entity_Id) return GL_Relationship is
   begin
      if PK_Is_Reference (PK) then
         return (if Is_Unconstrained_Array (TE)
                   and then PK /= Foreign_By_Reference
                 then Fat_Pointer else Reference);
      else
         return Data;
      end if;
   end Relationship_For_PK;

   ----------------------------
   -- Create_Subprogram_Type --
   ----------------------------

   function Create_Subprogram_Type (Def_Ident : Entity_Id) return Type_T is
      Return_Type     : constant Entity_Id   := Full_Etype      (Def_Ident);
      RK              : constant Return_Kind := Get_Return_Kind (Def_Ident);
      LRK             : constant L_Ret_Kind  := Get_L_Ret_Kind  (Def_Ident);
      Foreign         : constant Boolean     :=
        Has_Foreign_Convention (Def_Ident);
      Adds_S_Link     : constant Boolean     :=
        Is_Type (Def_Ident) and then not Foreign;
      LLVM_Ret_Typ    : Type_T               :=
        (if    RK in None | Return_By_Parameter then Void_Type
         elsif RK = RK_By_Reference then Create_Access_Type (Return_Type)
         else  Create_Type (Return_Type));
      In_Args_Count   : constant Nat         :=
        Count_In_Params (Def_Ident) + (if Adds_S_Link then 1 else 0) +
          (if RK = Return_By_Parameter then 1 else 0);
      Out_Args_Count  : constant Nat         :=
        Count_Out_Params (Def_Ident) +
          (if LRK = Struct_Out_Subprog then 1 else 0);
      In_Arg_Types    : Type_Array (1 .. In_Args_Count);
      Out_Arg_Types   : Type_Array (1 .. Out_Args_Count);
      Param_Ent       : Entity_Id            :=
        First_Formal_With_Extras (Def_Ident);
      J               : Nat                  := 1;
      LLVM_Result_Typ : Type_T               := LLVM_Ret_Typ;

   begin
      --  If the return type has dynamic size, we need to add a parameter
      --  to which we pass the address for the return to be placed in.

      if RK = Return_By_Parameter then
         In_Arg_Types (1) := Create_Access_Type (Return_Type);
         LLVM_Ret_Typ := Void_Type;
         J := 2;
      end if;

      --  Associate an LLVM type with each Ada subprogram parameter

      while Present (Param_Ent) loop
         declare
            Param_Type : constant Node_Id    := Full_Etype (Param_Ent);
            PK         : constant Param_Kind := Get_Param_Kind (Param_Ent);

         begin
            if PK_Is_In (PK) then
               In_Arg_Types (J) :=
                 (if    PK = Foreign_By_Reference
                  then  Pointer_Type (Create_Type (Param_Type), 0)
                  elsif PK = PK_By_Reference
                  then  Create_Access_Type (Param_Type)
                  else  Create_Type (Param_Type));

               J := J + 1;
            end if;
         end;

         Next_Formal_With_Extras (Param_Ent);
      end loop;

      --  Set the argument for the static link, if any

      if Adds_S_Link then
         In_Arg_Types (J) := Void_Ptr_Type;
      end if;

      --  Now deal with the result type.  We've already set if it it's
      --  simply the return type.

      case LRK is
         when Void | Subprog_Return =>
            null;

         when Out_Return =>
            LLVM_Result_Typ :=
              Create_Type (Full_Etype (First_Out_Param (Def_Ident)));

         when Struct_Out | Struct_Out_Subprog =>
            J := 1;
            if LRK = Struct_Out_Subprog then
               Out_Arg_Types (J) := LLVM_Ret_Typ;
               J := J + 1;
            end if;

            Param_Ent := First_Out_Param (Def_Ident);
            while Present (Param_Ent) loop
               Out_Arg_Types (J) := Create_Type (Full_Etype (Param_Ent));
               J := J + 1;
               Next_Out_Param (Param_Ent);
            end loop;

            LLVM_Result_Typ := Build_Struct_Type (Out_Arg_Types);
      end case;

      return Fn_Ty (In_Arg_Types, LLVM_Result_Typ);
   end Create_Subprogram_Type;

   -----------------------------------
   -- Create_Subprogram_Access_Type --
   -----------------------------------

   function Create_Subprogram_Access_Type return Type_T is
   begin
      --  It would be nice to have the field of this struct to be the
      --  a pointer to the subprogram type, but it can't be because
      --  the signature of an access type doesn't include the
      --  possibility of an activation record while the actual
      --  subprogram might have one.  So we use a generic pointer for
      --  it and cast at the actual call.

      return Build_Struct_Type ((1 => Void_Ptr_Type, 2 => Void_Ptr_Type));
   end Create_Subprogram_Access_Type;

   ---------------------
   -- Build_Intrinsic --
   ---------------------

   function Build_Intrinsic
     (Kind : Overloaded_Intrinsic_Kind;
      Name : String;
      TE   : Entity_Id) return GL_Value
   is
      Width         : constant Uint   := Esize (TE);
      Full_Name     : constant String := Name & UI_Image (Width);
      LLVM_Typ      : constant Type_T := Create_Type (TE);
      Return_TE     : Entity_Id := TE;
      Fun_Ty        : Type_T;
      Result        : GL_Value;

   begin
      for J in 1 .. Intrinsic_Functions_Table.Last loop
         if Intrinsic_Functions_Table.Table (J).Name.all = Name
           and then Intrinsic_Functions_Table.Table (J).Width = Width
         then
            return Intrinsic_Functions_Table.Table (J).Func;
         end if;
      end loop;

      case Kind is
         when Unary =>
            Fun_Ty := Fn_Ty ((1 => LLVM_Typ), LLVM_Typ);

         when Binary =>
            Fun_Ty := Fn_Ty ((1 => LLVM_Typ, 2 => LLVM_Typ), LLVM_Typ);

         when Overflow =>
            Fun_Ty := Fn_Ty
              ((1 => LLVM_Typ, 2 => LLVM_Typ),
               Build_Struct_Type ((1 => LLVM_Typ, 2 => Int_Ty (1))));

         when Memcpy =>
            Return_TE := Standard_Void_Type;
            Fun_Ty := Fn_Ty
              ((1 => Void_Ptr_Type, 2 => Void_Ptr_Type,
                3 => LLVM_Size_Type, 4 => Int_Ty (32), 5 => Int_Ty (1)),
               Void_Type);

         when Memset =>
            Return_TE := Standard_Void_Type;
            Fun_Ty := Fn_Ty
              ((1 => Void_Ptr_Type, 2 => Int_Ty (8), 3 => LLVM_Size_Type,
                4 => Int_Ty (32), 5 => Int_Ty (1)),
               Void_Type);
      end case;

      Result := Add_Function (Full_Name, Fun_Ty, Return_TE);
      Set_Does_Not_Throw (Result);
      Intrinsic_Functions_Table.Append ((new String'(Name), Width, Result));
      return Result;
   end Build_Intrinsic;

   -------------------------
   -- Add_Global_Function --
   -------------------------

   function Add_Global_Function
     (S          : String;
      Subp_Type  : Type_T;
      TE         : Entity_Id;
      Can_Throw  : Boolean := False;
      Can_Return : Boolean := True) return GL_Value
   is
      Func : GL_Value := Get_Dup_Global_Value (S);

   begin
      --  If we've already built a function for this, return it, after
      --  being sure it's in the same type that we need.

      if Present (Func) then
         return G_From (Pointer_Cast (IR_Builder,
                                      LLVM_Value (Func),
                                      Pointer_Type (Subp_Type, 0), S),
                        Func);
      else
         Func := Add_Function (S, Subp_Type, TE);
         if not Can_Throw then
            Set_Does_Not_Throw (Func);
         end if;

         if not Can_Return then
            Set_Does_Not_Return (Func);
         end if;

         if Can_Throw and not Can_Return then
            Add_Cold_Attribute (Func);
         end if;

         Set_Dup_Global_Value (S, Func);
         return Func;
      end if;

   end Add_Global_Function;

   --------------------------
   -- Get_Default_Alloc_Fn --
   --------------------------

   function Get_Default_Alloc_Fn return GL_Value is
   begin
      if No (Default_Alloc_Fn) then
         Default_Alloc_Fn :=
           Add_Global_Function ("__gnat_malloc", Fn_Ty ((1 => LLVM_Size_Type),
                                                        Void_Ptr_Type),
                                Standard_A_Char);
      end if;

      return Default_Alloc_Fn;
   end Get_Default_Alloc_Fn;

   -------------------------
   -- Get_Default_Free_Fn --
   -------------------------

   function Get_Default_Free_Fn return GL_Value is
   begin
      if No (Default_Free_Fn) then
         Default_Free_Fn :=
           Add_Global_Function ("__gnat_free",
                                Fn_Ty ((1 => Void_Ptr_Type), Void_Type),
                                Standard_Void_Type);
      end if;

      return Default_Free_Fn;
   end Get_Default_Free_Fn;

   ---------------------------
   -- Get_Memory_Compare_Fn --
   ---------------------------

   function Get_Memory_Compare_Fn return GL_Value is
   begin
      if No (Memory_Compare_Fn) then
         Memory_Compare_Fn := Add_Global_Function
           ("memcmp",
            Fn_Ty ((1 => Void_Ptr_Type, 2 => Void_Ptr_Type,
                    3 => LLVM_Size_Type),
                   Create_Type (Standard_Integer)),
            Standard_Integer);
      end if;

      return Memory_Compare_Fn;
   end Get_Memory_Compare_Fn;

   -----------------------
   -- Get_Stack_Save_Fn --
   -----------------------

   function Get_Stack_Save_Fn return GL_Value is
   begin
      if No (Stack_Save_Fn) then
         Stack_Save_Fn := Add_Function
           ("llvm.stacksave", Fn_Ty ((1 .. 0 => <>), Void_Ptr_Type),
            Standard_A_Char);
         Set_Does_Not_Throw (Stack_Save_Fn);
      end if;

      return Stack_Save_Fn;
   end Get_Stack_Save_Fn;

   --------------------------
   -- Get_Stack_Restore_Fn --
   --------------------------

   function Get_Stack_Restore_Fn return GL_Value is
   begin
      if No (Stack_Restore_Fn) then
         Stack_Restore_Fn := Add_Function
           ("llvm.stackrestore",
            Fn_Ty ((1 => Void_Ptr_Type), Void_Type), Standard_Void_Type);
         Set_Does_Not_Throw (Stack_Restore_Fn);
      end if;

      return Stack_Restore_Fn;
   end Get_Stack_Restore_Fn;

   -----------------------
   -- Get_Tramp_Init_Fn --
   -----------------------

   function Get_Tramp_Init_Fn return GL_Value is
   begin
      if No (Tramp_Init_Fn) then
         Tramp_Init_Fn := Add_Function
           ("llvm.init.trampoline",
            Fn_Ty ((1 => Void_Ptr_Type, 2 => Void_Ptr_Type,
                    3 => Void_Ptr_Type),
                   Void_Type),
            Standard_Void_Type);
         Set_Does_Not_Throw (Tramp_Init_Fn);
      end if;

      return Tramp_Init_Fn;
   end Get_Tramp_Init_Fn;

   -------------------------
   -- Get_Tramp_Adjust_Fn --
   -------------------------

   function Get_Tramp_Adjust_Fn return GL_Value is
   begin
      if No (Tramp_Adjust_Fn) then
         Tramp_Adjust_Fn := Add_Function
           ("llvm.adjust.trampoline",
            Fn_Ty ((1 => Void_Ptr_Type), Void_Ptr_Type), Standard_A_Char);
         Set_Does_Not_Throw (Tramp_Adjust_Fn);
      end if;

      return Tramp_Adjust_Fn;
   end Get_Tramp_Adjust_Fn;

   ---------------------
   -- Make_Trampoline --
   ---------------------

   function Make_Trampoline
     (TE : Entity_Id; Fn, Static_Link : GL_Value) return GL_Value
   is
      Tramp  : constant GL_Value :=
        Array_Alloca (Standard_Short_Short_Integer, Size_Const_Int (ULL (72)),
                      "tramp");
      Cvt_Fn : constant GL_Value := Pointer_Cast (Fn, Standard_A_Char);

   begin
      --  We have to initialize the trampoline and then adjust it and return
      --  that result.

      Call (Get_Tramp_Init_Fn, (1 => Tramp, 2 => Cvt_Fn, 3 => Static_Link));
      return G_Is_Relationship
        (Call (Get_Tramp_Adjust_Fn, Standard_A_Char, (1 => Tramp)),
         TE, Trampoline);

   end Make_Trampoline;

   -------------------------------
   -- Get_Activation_Record_Ptr --
   -------------------------------

   function Get_Activation_Record_Ptr
     (V : GL_Value; E : Entity_Id) return GL_Value
   is
      Need_Type   : constant Entity_Id := Full_Scope (E);
      Have_Type   : constant Entity_Id := Full_Designated_Type (V);
      First_Field : constant Entity_Id :=
        First_Component_Or_Discriminant (Have_Type);

   begin
      --  If V points to an object that E is a component of, return it.
      --  Otherwise, go up the chain by getting the first field of V's
      --  record and dereferencing it.

      if Need_Type = Have_Type then
         return V;
      else
         pragma Assert (Present (First_Field)
                          and then Is_Access_Type (Full_Etype (First_Field)));
         return Get_Activation_Record_Ptr
           (Load (Record_Field_Offset (V, First_Field)), E);
      end if;
   end Get_Activation_Record_Ptr;

   --------------------------------
   -- Get_From_Activation_Record --
   --------------------------------

   function Get_From_Activation_Record (E : Entity_Id) return GL_Value is
   begin
      --  See if this is a type of object that's passed in activation
      --  records, if this object is allocated space in an activation
      --  record, if we have an activation record as a parameter of this
      --  subprogram, and if this isn't a reference to the variable
      --  in its own subprogram.  If so, get the object from the activation
      --  record.  We return the address from the record so we can either
      --  give an LValue or an expression.

      if Ekind_In (E, E_Constant, E_Variable, E_In_Parameter, E_Out_Parameter,
                   E_In_Out_Parameter, E_Loop_Parameter)
        and then Present (Activation_Record_Component (E))
        and then Present (Activation_Rec_Param)
        and then Get_Value (Enclosing_Subprogram (E)) /= Current_Func
      then
         declare
            TE             : constant Entity_Id := Full_Etype (E);
            Component      : constant Entity_Id :=
              Activation_Record_Component (E);
            Activation_Rec : constant GL_Value  :=
              Get_Activation_Record_Ptr (Activation_Rec_Param, Component);
            Pointer       : constant GL_Value  :=
              Record_Field_Offset (Activation_Rec, Component);
            Value         : constant GL_Value  := Load (Pointer);

         begin
            --  If TE is unconstrained, we have an access type, which is a
            --  fat pointer.  Convert it to a reference to the underlying
            --  type.  Otherwise, this is a System.Address which needs to
            --  be converted to a pointer.

            if Is_Unconstrained_Array (TE) then
               return From_Access (Value);
            else
               return Int_To_Ref (Value, TE);
            end if;
         end;
      else
         return No_GL_Value;
      end if;
   end Get_From_Activation_Record;

   -------------------
   -- Emit_One_Body --
   -------------------

   procedure Emit_One_Body (N : Node_Id) is
      Spec            : constant Node_Id     := Get_Acting_Spec (N);
      Func            : constant GL_Value    := Emit_Subprogram_Decl (Spec);
      Def_Ident       : constant Entity_Id   := Defining_Entity      (Spec);
      Return_Typ      : constant Entity_Id   := Full_Etype      (Def_Ident);
      RK              : constant Return_Kind := Get_Return_Kind (Def_Ident);
      LRK             : constant L_Ret_Kind  := Get_L_Ret_Kind  (Def_Ident);
      Param_Num       : Nat                  := 0;
      LLVM_Param      : GL_Value;
      Param           : Entity_Id;

   begin
      Current_Subp := Def_Ident;
      Enter_Subp (Func);
      Push_Debug_Scope
        (Create_Subprogram_Debug_Info (Func, Def_Ident, N,
                                       Get_Name_String (Chars (Def_Ident)),
                                       Get_Ext_Name (Def_Ident)));

      --  If the return type has dynamic size, we've added a parameter
      --  that's passed the address to which we want to copy our return
      --  value.

      if RK = Return_By_Parameter then
         LLVM_Param := Get_Param (Func, Param_Num, Return_Typ,
                                  (if Is_Unconstrained_Array (Return_Typ)
                                   then Fat_Pointer else Reference));
         Set_Value_Name (LLVM_Value (LLVM_Param), "_return");
         Return_Address_Param := LLVM_Param;
         Param_Num := Param_Num + 1;
      end if;

      Push_Block;
      Entry_Block_Allocas := Get_Current_Position;
      Param := First_Formal_With_Extras (Def_Ident);
      while Present (Param) loop
         declare
            type String_Access is access constant String;

            PK     : constant Param_Kind      := Get_Param_Kind (Param);
            TE     : constant Entity_Id       := Full_Etype (Param);
            R      : constant GL_Relationship := Relationship_For_PK (PK, TE);
            V      : constant GL_Value        :=
              (if   PK_Is_In (PK) then Get_Param (Func, Param_Num, TE, R)
               else No_GL_Value);
            P_Name : aliased constant String  := Get_Name (Param);
            A_Name : aliased constant String  := P_Name & ".addr";
            Name   : String_Access            := P_Name'Access;

         begin
            Set_Debug_Pos_At_Node (Param);
            if Present (V) then
               Set_Value_Name (V, Get_Name (Param));
               Name := A_Name'Access;
            end if;

            --  If this is an out parameter, we have to make a variable
            --  for it, possibly initialized to our parameter value if this
            --  is also an in parameter.  Otherwise, we can use the parameter.
            --  unchanged.

            if PK_Is_Out (PK) then
               LLVM_Param := Allocate_For_Type (TE, TE, Param, V, Name.all);
            else
               LLVM_Param := V;
            end if;

            if PK = Activation_Record then
               Activation_Rec_Param := LLVM_Param;
            end if;

            --  Add the parameter to the environnment

            Set_Value (Param, LLVM_Param);
            if PK_Is_In (PK) then
               Param_Num := Param_Num + 1;
            end if;

            Next_Formal_With_Extras (Param);
         end;
      end loop;

      Emit_Decl_Lists (Declarations (N), No_List);
      Emit (Handled_Statement_Sequence (N));

      --  If the last instrution isn't a terminator, add a return, but
      --  use an access type if this is a dynamic type or a return by ref.

      if not Are_In_Dead_Code then
         case LRK is
            when Void =>
               Build_Ret_Void;

            when Subprog_Return =>
               if RK = RK_By_Reference then
                  Build_Ret (Get_Undef_Ref (Return_Typ));
               else
                  Build_Ret (Get_Undef (Return_Typ));
               end if;

            when Out_Return =>
               Build_Ret (Get_Undef (Full_Etype
                                       (First_Out_Param (Current_Subp))));

            when Struct_Out | Struct_Out_Subprog =>
               Build_Ret (Get_Undef_Fn_Ret (Current_Func));
         end case;
      end if;

      Pop_Block;

      --  If we're in dead code here, it means that we made a label for the
      --  end of a block, but didn't do anything with it.  So mark it as
      --  unreachable.  ??? We need to sort this out sometime.

      if not Are_In_Dead_Code then
         Build_Unreachable;
      end if;

      Pop_Debug_Scope;
      Leave_Subp;
      Reset_Block_Tables;
      Current_Subp := Empty;
   end Emit_One_Body;

   ----------------------
   -- Add_To_Elab_Proc --
   ----------------------

   procedure Add_To_Elab_Proc (N : Node_Id; For_Type : Entity_Id := Empty) is
   begin
      if Elaboration_Table.Last = 0
        or else Elaboration_Table.Table (Elaboration_Table.Last).N /= N
      then
         Check_Elaboration_Code_Allowed (N);
         Elaboration_Table.Append ((N => N, For_Type => For_Type));
      end if;
   end Add_To_Elab_Proc;

   --------------------
   -- Emit_Elab_Proc --
   --------------------

   procedure Emit_Elab_Proc
     (N : Node_Id; Stmts : Node_Id; CU : Node_Id; Suffix : String) is
      U          : constant Node_Id  := Defining_Unit_Name (N);
      Unit       : constant Node_Id  :=
        (if Nkind (U) = N_Defining_Program_Unit_Name
         then Defining_Identifier (U) else U);
      S_List     : constant List_Id  :=
        (if No (Stmts) then No_List else Statements (Stmts));
      Name       : constant String   :=
        Get_Name_String (Chars (Unit)) & "___elab" & Suffix;
      Work_To_Do : constant Boolean  :=
        Elaboration_Table.Last /= 0 or else Has_Non_Null_Statements (S_List);
      Elab_Type  : constant Type_T   := Fn_Ty ((1 .. 0 => <>), Void_Type);
      LLVM_Func  : GL_Value;

   begin
      --  If nothing to elaborate, do nothing

      if Nkind (CU) /= N_Compilation_Unit or else not Work_To_Do then
         return;
      end if;

      --  Otherwise, show there will be elaboration code and emit it

      if Nkind (CU) = N_Compilation_Unit then
         Set_Has_No_Elaboration_Code (CU, False);
      end if;

      if Name = "ada_main___elabb" and Present (Ada_Main_Elabb) then
         LLVM_Func := Ada_Main_Elabb;
      else
         LLVM_Func := Add_Function (Name, Elab_Type, Standard_Void_Type);
      end if;

      Enter_Subp (LLVM_Func);
      Push_Debug_Scope
        (Create_Subprogram_Debug_Info
           (LLVM_Func, Unit, N, Get_Name_String (Chars (Unit)), Name));
      Set_Debug_Pos_At_Node (N);
      Push_Block;
      In_Elab_Proc := True;

      for J in 1 .. Elaboration_Table.Last loop
         declare
            Stmt : constant Node_Id   := Elaboration_Table.Table (J).N;
            Typ  : constant Entity_Id := Elaboration_Table.Table (J).For_Type;

         begin
            if Present (Typ) then
               Set_Value (Stmt, Emit_Convert_Value (Stmt, Typ));
            else
               --  If Stmt is an N_Handled_Sequence_Of_Statements, it
               --  must have come from a package body.  Make a block around
               --  it so exceptions will work properly, if needed.

               if Nkind (Stmt) = N_Handled_Sequence_Of_Statements then
                  Push_Block;
                  Emit (Stmt);
                  Pop_Block;
               else
                  Emit (Stmt);
               end if;
            end if;
         end;
      end loop;

      --  Emit the statements after clearing the special code flag since
      --  we want to handle them normally: this will be the first time we
      --  see them, unlike any that were previously partially processed
      --  as declarations.

      In_Elab_Proc := False;
      Elaboration_Table.Set_Last (0);
      Start_Block_Statements
        (Empty, (if No (Stmts) then No_List else Exception_Handlers (Stmts)));
      Emit (S_List);
      Pop_Block;
      Build_Ret_Void;
      Pop_Debug_Scope;
      Leave_Subp;
   end Emit_Elab_Proc;

   --------------------------
   -- Emit_Subprogram_Body --
   --------------------------

   procedure Emit_Subprogram_Body (N : Node_Id) is
      Nest_Table_First : constant Nat := Nested_Functions_Table.Last + 1;

   begin
      --  If we're not at library level, this a nested function.  Defer it
      --  until we complete elaboration of the enclosing function.  But do
      --  ensure that the spec has been elaborated.

      if not Library_Level then
         Discard (Emit_Subprogram_Decl (Get_Acting_Spec (N)));
         Nested_Functions_Table.Append (N);
         return;
      end if;

      --  Otherwise, elaborate this function and then any nested functions
      --  within in.

      Emit_One_Body (N);

      for J in Nest_Table_First .. Nested_Functions_Table.Last loop
         Emit_Subprogram_Body (Nested_Functions_Table.Table (J));
      end loop;

      Nested_Functions_Table.Set_Last (Nest_Table_First);
   end Emit_Subprogram_Body;

   ---------------------------
   -- Emit_Return_Statement --
   ---------------------------

   procedure Emit_Return_Statement (N : Node_Id) is
      TE  : constant Entity_Id   := Full_Etype (Current_Subp);
      RK  : constant Return_Kind := Get_Return_Kind (Current_Subp);
      LRK : constant L_Ret_Kind  := Get_L_Ret_Kind (Current_Subp);
      V   : GL_Value             := No_GL_Value;

   begin
      --  First, generate any neded fixups for this.  Then see what kind of
      --  return we're doing.

      Emit_Fixups_For_Return;

      --  Start by handling our expression, if any

      if Present (Expression (N)) then
         declare
            Expr : constant Node_Id :=
              Strip_Complex_Conversions (Expression (N));

         begin
            pragma Assert (RK /= None);

            --  If there's a parameter for the address to which to copy the
            --  return value, do the copy instead of returning the value.

            if RK = Return_By_Parameter then
               Emit_Assignment (Return_Address_Param, Expr,
                                No_GL_Value, True, True);

            --  If this function returns unconstrained, allocate memory for
            --  the return value, copy the data to be returned to there,
            --  and return an access (fat pointer) to the value.  If this
            --  is a return-by-reference function, return a reference to
            --  this value.  However, if a return-by-reference function has
            --  a Storage_Pool, that means we must allocate memory in that
            --  pool, copy the return value to it, and return that address.

            elsif Is_Unconstrained_Array (TE)
              or else (RK = RK_By_Reference
                         and then Present (Storage_Pool (N)))
            then
               V := (Heap_Allocate_For_Type
                       (TE, Full_Etype (Expr), Emit_Expression (Expr),
                        Procedure_To_Call (N), Storage_Pool (N)));

            elsif RK = RK_By_Reference then
               V := Convert_Ref (Emit_LValue (Expr), TE);

            else
               V := Emit_Convert_Value (Expr, TE);
            end if;
         end;
      else
         pragma Assert (RK = None);
      end if;

      --  Now see what the actual return value of this LLVM function should be

      case LRK is
         when Void =>
            Build_Ret_Void;

         when Subprog_Return =>
            Build_Ret (V);

         when Out_Return =>
            Build_Ret (Get (Get_Value (First_Out_Param (Current_Subp)), Data));

         when Struct_Out | Struct_Out_Subprog =>

            declare
               Retval : GL_Value  := Get_Undef_Fn_Ret (Current_Func);
               Param  : Entity_Id := First_Out_Param  (Current_Subp);
               J      : unsigned  := 0;

            begin
               if LRK = Struct_Out_Subprog then
                  Retval := Insert_Value (Retval, V, J);
                  J      := J + 1;
               end if;

               while Present (Param) loop
                  Retval :=
                    Insert_Value (Retval, Get (Get_Value (Param), Data), J);
                  J      := J + 1;
                  Next_Out_Param (Param);
               end loop;

               Build_Ret (Retval);
            end;
      end case;

   end Emit_Return_Statement;

   ---------------------
   -- Get_Static_Link --
   ---------------------

   function Get_Static_Link (N : Node_Id) return GL_Value is
      Subp        : constant Entity_Id  :=
        (if Nkind (N) in N_Entity then N else Entity (N));
      Parent      : constant Entity_Id  := Enclosing_Subprogram (Subp);
      Ent_Caller  : Subp_Entry;
      Ent         : Subp_Entry;
      Result      : GL_Value;

   begin

      if Present (Parent) then
         Ent        := Subps.Table (Subp_Index (Parent));
         Ent_Caller := Subps.Table (Subp_Index (Current_Subp));

         if Parent = Current_Subp then
            Result := (if Present (Ent.ARECnP)
                       then Get (Get_Value (Ent.ARECnP), Data)
                       else Get_Undef (Standard_A_Char));
         elsif No (Ent_Caller.ARECnF) then
            return Get_Undef (Standard_A_Char);
         else
            Result := Get_Value (Ent_Caller.ARECnF);

            --  Go levels up via the ARECnU field if needed.  Each time,
            --  get the new type from the first field of the record that
            --  it points to.

            for J in 1 .. Ent_Caller.Lev - Ent.Lev - 1 loop
               Result :=
                 Load (GEP (Full_Etype (First_Component_Or_Discriminant
                                          (Full_Designated_Type (Result))),
                            Result, (1 => Const_Null_32, 2 => Const_Null_32),
                            "ARECnF.all.ARECnU"));
            end loop;
         end if;

         return Pointer_Cast (Result, Standard_A_Char, "static-link");
      else
         return Get_Undef (Standard_A_Char);
      end if;
   end Get_Static_Link;

   ----------------
   -- Call_Alloc --
   ----------------

   function Call_Alloc
     (Proc : Entity_Id; Args : GL_Value_Array) return GL_Value
   is
      Func           : constant GL_Value := Emit_Safe_LValue (Proc);
      Args_With_Link : GL_Value_Array (Args'First .. Args'Last + 1);
      S_Link         : GL_Value;

   begin
      if Subps_Index (Proc) /= Uint_0
        and then Present (Subps.Table (Subp_Index (Proc)).ARECnF)
      then
         --  This needs a static link.  Get it, convert it to the precise
         --  needed type, and then create the new argument list.

         S_Link := Pointer_Cast (Get_Static_Link (Proc),
                                 Full_Etype (Extra_Formals (Proc)));
         Args_With_Link (Args'Range) := Args;
         Args_With_Link (Args_With_Link'Last) := S_Link;
         return Call (Func, Size_Type, Args_With_Link);
      else
         return Call (Func, Size_Type, Args);
      end if;
   end Call_Alloc;

   ------------------
   -- Call_Dealloc --
   ------------------

   procedure Call_Dealloc (Proc : Entity_Id; Args : GL_Value_Array) is
      Func           : constant GL_Value := Emit_Safe_LValue (Proc);
      Args_With_Link : GL_Value_Array (Args'First .. Args'Last + 1);
      S_Link         : GL_Value;

   begin
      if Subps_Index (Proc) /= Uint_0
        and then Present (Subps.Table (Subp_Index (Proc)).ARECnF)
      then
         --  This needs a static link.  Get it, convert it to the precise
         --  needed type, and then create the new argument list.

         S_Link := Pointer_Cast (Get_Static_Link (Proc),
                                 Full_Etype (Extra_Formals (Proc)));
         Args_With_Link (Args'Range) := Args;
         Args_With_Link (Args_With_Link'Last) := S_Link;
         Call (Func, Args_With_Link);
      else
         Call (Func, Args);
      end if;
   end Call_Dealloc;

   --------------------
   -- Name_To_RMW_Op --
   --------------------

   function Name_To_RMW_Op
     (S           : String;
      Index       : Integer;
      End_Index   : out Integer;
      Op          : out Atomic_RMW_Bin_Op_T) return Boolean
   is
      type RMW_Op is record
         Length : Integer;
         Name   : String (1 .. 4);
         Op     : Atomic_RMW_Bin_Op_T;
      end record;
      type RMW_Op_Array is array (Integer range <>) of RMW_Op;

      Len : Integer;
      Ops : constant RMW_Op_Array :=
        ((4, "xchg", Atomic_RMW_Bin_Op_Xchg),
         (3, "add ", Atomic_RMW_Bin_Op_Add),
         (3, "sub ", Atomic_RMW_Bin_Op_Sub),
         (3, "and ", Atomic_RMW_Bin_Op_And),
         (4, "nand", Atomic_RMW_Bin_Op_Nand),
         (2, "or  ", Atomic_RMW_Bin_Op_Or),
         (3, "xor ", Atomic_RMW_Bin_Op_Xor),
         (3, "max ", Atomic_RMW_Bin_Op_Max),
         (3, "min ", Atomic_RMW_Bin_Op_Min),
         (4, "umax", Atomic_RMW_Bin_Op_U_Max),
         (4, "umin", Atomic_RMW_Bin_Op_U_Min));

   begin
      for J in Ops'Range loop
         Len := Ops (J).Length;
         if S'Last > Index + Len - 1
           and then S (Index .. Index + Len - 1) = Ops (J).Name (1 .. Len)
         then
            End_Index := Index + Len;
            Op        := Ops (J).Op;
            return True;
         end if;
      end loop;

      return False;
   end Name_To_RMW_Op;

   --------------------
   -- Emit_Sync_Call --
   --------------------

   function Emit_Sync_Call (N : Node_Id; S : String) return GL_Value is
      Ptr        : constant Node_Id := First_Actual (N);
      Index      : Integer := S'First + 7;
      Val        : Node_Id;
      Op         : Atomic_RMW_Bin_Op_T;
      Op_Back    : Boolean;
      New_Index  : Integer;
      TE, BT, PT : Entity_Id;
      Type_Size  : ULL;
      Value      : GL_Value;
      Result     : GL_Value;

   begin
      --  This is supposedly a __sync builtin.  Parse it to see what it
      --  tells us to do.  If anything is wrong with the builtin or its
      --  operands, just return No_GL_Value and a normal call will result,
      --  which will produce a link error.  ???  We could produce warnings
      --  here.
      --
      --  We need to have "Op_and_fetch" or "fetch_and_Op".

      if Name_To_RMW_Op (S, Index, New_Index, Op)
        and then S'Last > New_Index + 9
        and then S (New_Index .. New_Index + 9) = "_and_fetch"
      then
         Op_Back := True;
         Index   := New_Index + 10;
      elsif S'Last > Index + 9 and then S (Index .. Index + 9) = "fetch_and_"
        and then Name_To_RMW_Op (S, Index + 10, New_Index, Op)
      then
         Op_Back := False;
         Index   := New_Index;
      else
         return No_GL_Value;
      end if;

      --  There must be exactly two actuals with the second an elementary
      --  type and the first an access type to it.

      if No (Ptr) then
         return No_GL_Value;
      end if;

      Val := Next_Actual (Ptr);
      if No (Val) or else Present (Next_Actual (Val)) then
         return No_GL_Value;
      end if;

      TE  := Full_Etype (Val);
      PT  := Full_Etype (Ptr);
      BT  := Implementation_Base_Type (TE);
      if not Is_Elementary_Type (TE)
        or else not Is_Access_Type (PT)
        or else Implementation_Base_Type (Full_Designated_Type (PT)) /= BT
      then
         return No_GL_Value;
      end if;

      --  Finally, verify that the size of the type matches the builtin name
      if S'Last < Index + 1 then
         return No_GL_Value;
      end if;

      Type_Size := Get_LLVM_Type_Size (Create_Type (TE));
      if not (S (Index .. Index + 1) = "_1" and then Type_Size = 1)
        and then not (S (Index .. Index + 1) = "_2" and then Type_Size = 2)
        and then not (S (Index .. Index + 1) = "_4" and then Type_Size = 4)
        and then not (S (Index .. Index + 1) = "_8" and then Type_Size = 8)
      then
         return No_GL_Value;
      end if;

      --  Now we can emit the operation

      Value  := Emit_Expression (Val);
      Result := Atomic_RMW (Op, Emit_Expression (Ptr), Value);

      --  If we want the value before the operation, we're done.  Otherwise,
      --  we have to do the operation.

      if not Op_Back then
         return Result;
      end if;

      case Op is
         when Atomic_RMW_Bin_Op_Xchg =>
            return Result;

         when Atomic_RMW_Bin_Op_Add =>
            return NSW_Add (Result, Value);

         when Atomic_RMW_Bin_Op_Sub =>
            return NSW_Sub (Result, Value);

         when Atomic_RMW_Bin_Op_And =>
            return Build_And (Result, Value);

         when Atomic_RMW_Bin_Op_Nand =>
            return Build_Not (Build_And (Result, Value));

         when Atomic_RMW_Bin_Op_Or =>
            return Build_Or (Result, Value);

         when Atomic_RMW_Bin_Op_Xor =>
            return Build_Xor (Result, Value);

         when Atomic_RMW_Bin_Op_Max | Atomic_RMW_Bin_Op_U_Max =>
            return Build_Max (Result, Value);

         when Atomic_RMW_Bin_Op_Min | Atomic_RMW_Bin_Op_U_Min =>
            return Build_Min (Result, Value);
      end case;

   end Emit_Sync_Call;

   ---------------------
   -- Emit_Bswap_Call --
   ---------------------

   function Emit_Bswap_Call (N : Node_Id; S : String) return GL_Value is
      Val       : constant Node_Id := First_Actual (N);
      TE        : Entity_Id;
      Type_Size : ULL;

   begin
      --  This is supposedly a __builtin_bswap builtin.  Verify that it is.
      --  There must be exactly one actual.

      if No (Val) or else Present (Next_Actual (Val)) then
         return No_GL_Value;
      end if;

      TE := Full_Etype (Val);
      if not Is_Elementary_Type (TE) then
         return No_GL_Value;
      end if;

      Type_Size := Get_LLVM_Type_Size_In_Bits (Create_Type (TE));
      if not (S (S'Last - 1 .. S'Last) = "16" and then Type_Size = 16)
        and then not (S (S'Last - 1 .. S'Last) = "32" and then Type_Size = 32)
        and then not (S (S'Last - 1 .. S'Last) = "64" and then Type_Size = 64)
      then
         return No_GL_Value;
      end if;

      return Call (Build_Intrinsic (Unary, "llvm.bswap.i", TE), TE,
                   (1 => Emit_Expression (Val)));
   end Emit_Bswap_Call;

   -------------------------
   -- Emit_Intrinsic_Call --
   -------------------------

   function Emit_Intrinsic_Call (N : Node_Id; Subp : Entity_Id) return GL_Value
   is
      Fn_Name : constant String := Get_Ext_Name (Subp);

   begin
      --  First see if this is a __sync class of subprogram

      if Fn_Name'Length > 7 and then Fn_Name (1 .. 7) = "__sync_" then
         return Emit_Sync_Call (N, Fn_Name);

      --  Next, check for __builtin_bswap

      elsif Fn_Name'Length > 15 and then Fn_Name (1 .. 15) = "__builtin_bswap"
      then
         return Emit_Bswap_Call (N, Fn_Name);
      end if;

      --  ??? That's all we support for the moment

      return No_GL_Value;
   end Emit_Intrinsic_Call;

   ---------------------------
   -- Has_Activation_Record --
   ---------------------------

   function Has_Activation_Record
     (Def_Ident : Entity_Id) return Boolean
   is
      Formal : Entity_Id := First_Formal_With_Extras (Def_Ident);

   begin
      --  In the type case, we don't consider it as having an activation
      --  record for foreign conventions because we will have had to make
      --  a trampoline directly at the 'Access or 'Address.

      if Is_Type (Def_Ident) and then Has_Foreign_Convention (Def_Ident) then
         return False;
      end if;

      --  Otherwise, see if any parameter is an activation record.
      --  ??? For now, at least, check if it's empty.

      while Present (Formal) loop
         exit when  Ekind (Formal) = E_In_Parameter
           and then Is_Activation_Record (Formal)
           and then Present (First_Component_Or_Discriminant
                               (Full_Designated_Type (Full_Etype (Formal))));
         Next_Formal_With_Extras (Formal);
      end loop;

      return Present (Formal);
   end Has_Activation_Record;

   --------------------------------
   -- Emit_Subprogram_Identifier --
   --------------------------------

   function Emit_Subprogram_Identifier
     (Def_Ident : Entity_Id; N : Node_Id; TE : Entity_Id) return GL_Value
   is
      V  : GL_Value := Get_Value (Def_Ident);

   begin
      --  If this has an Alias, use that

      if Present (Alias (Def_Ident)) then
         return Emit_Identifier (Alias (Def_Ident));
      end if;

      --  If we haven't gotten one yet, make it

      if No (V) then
         V := Create_Subprogram (Def_Ident);
      end if;

      --  If we're elaborating this for 'Access or 'Address, we want the
      --  actual subprogram type here, not the type of the return value,
      --  which is what TE is set to.  We also may have to make a
      --  trampoline or Fat_Reference_To_Subprogram here since it's too
      --  late to make it in Get because it doesn't know what subprogram it
      --  was for.

      if Nkind (Parent (N)) = N_Attribute_Reference then
         declare
            S_Link : constant GL_Value     := Get_Static_Link (N);
            Ref    : constant Node_Id      := Parent (N);
            Typ    : constant Entity_Id    := Full_Etype (Ref);
            Attr   : constant Attribute_Id :=
              Get_Attribute_Id (Attribute_Name (Ref));

         begin
            if Is_Access_Type (Typ) then
               declare
                  DT     : constant Entity_Id := Full_Designated_Type (Typ);
                  S_Link : constant GL_Value  := Get_Static_Link (N);

               begin
                  if Has_Activation_Record (Def_Ident)
                    and then (Has_Foreign_Convention (Typ) /=
                                Has_Foreign_Convention (Def_Ident))
                  then
                     Error_Msg_Node_1 := Def_Ident;
                     Error_Msg_Node_2 := Typ;
                     Error_Msg_N
                       ("either access type & and subprogram &", Ref);
                     Error_Msg_N
                       ("\Convention Ada or neither may be since ", Ref);
                     Error_Msg_NE
                       ("\&references parent variables", Ref, Def_Ident);
                  end if;

                  if Has_Foreign_Convention (Typ) then
                     return (if   Has_Activation_Record (Def_Ident)
                             then Make_Trampoline (DT, V, S_Link)
                             else G_Is_Relationship (V, DT, Trampoline));
                  else
                     return Insert_Value
                       (Insert_Value (Get_Undef_Relationship
                                        (DT, Fat_Reference_To_Subprogram),
                                      S_Link, 1),
                        Pointer_Cast (V, Standard_A_Char), 0);
                  end if;
               end;
            elsif Attr = Attribute_Address then
               if Has_Activation_Record (Def_Ident)
                 and then not Has_Foreign_Convention (Def_Ident)
               then
                  Error_Msg_N
                    ("cannot take address of Convention Ada subprogram ", Ref);
                  Error_Msg_NE
                    ("\& which references parent variables", Ref, Def_Ident);
               end if;

               return (if   Has_Activation_Record (Def_Ident)
                       then Make_Trampoline (TE, V, S_Link) else V);
            end if;
         end;
      end if;

      return V;

   end Emit_Subprogram_Identifier;

   ---------------
   -- Emit_Call --
   ---------------

   function Emit_Call (N : Node_Id) return GL_Value is

      procedure Write_Back (In_LHS, In_RHS : GL_Value)
        with Pre => Present (In_LHS) and then Present (In_RHS)
                    and then not Is_Reference (In_RHS)
                    and then Is_Reference (In_LHS);
      --  Write the value in In_RHS to the location In_LHS

      Subp             : Node_Id              := Name (N);
      Our_Return_Typ   : constant Entity_Id   := Full_Etype (N);
      Direct_Call      : constant Boolean     :=
        Nkind (Subp) /= N_Explicit_Dereference;
      Subp_Typ         : constant Entity_Id   :=
        (if Direct_Call then Entity (Subp) else Full_Etype (Subp));
      RK               : constant Return_Kind := Get_Return_Kind  (Subp_Typ);
      LRK              : constant L_Ret_Kind  := Get_L_Ret_Kind   (Subp_Typ);
      Return_Typ       : constant Entity_Id   := Full_Etype       (Subp_Typ);
      Orig_Arg_Count   : constant Nat         := Count_In_Params  (Subp_Typ);
      Out_Arg_Count    : constant Nat         := Count_Out_Params (Subp_Typ);
      Out_Param        : Entity_Id            := First_Out_Param  (Subp_Typ);
      In_Idx           : Nat                  := 1;
      Out_Idx          : Nat                  := 1;
      Ret_Idx          : Nat                  := 1;
      Result           : GL_Value             := No_GL_Value;
      Foreign          : constant Boolean     :=
        Has_Foreign_Convention (Subp_Typ);
      This_Adds_S_Link : constant Boolean     :=
        not Direct_Call and not Foreign;
      Arg_Count        : constant Nat         :=
        Orig_Arg_Count + (if This_Adds_S_Link then 1 else 0) +
          (if RK = Return_By_Parameter then 1 else 0);
      Args             : GL_Value_Array (1 .. Arg_Count);
      Out_LHSs         : GL_Value_Array (1 .. Out_Arg_Count);
      Actual_Return    : GL_Value;
      S_Link           : GL_Value;
      LLVM_Func        : GL_Value;
      Param            : Node_Id;
      Actual           : Node_Id;

      ----------------
      -- Write_Back --
      ----------------

      procedure Write_Back (In_LHS, In_RHS : GL_Value) is
         LHS      : GL_Value           := In_LHS;
         RHS      : GL_Value           := In_RHS;
         LHS_TE   : constant Entity_Id := Related_Type (LHS);
         RHS_TE   : constant Entity_Id := Related_Type (RHS);

      begin
         --  We've looked through any conversions in the actual and
         --  evaluated the actual LHS to be assigned before the call.  We
         --  wouldn't be here is this were a dynamic-sized type, and we
         --  know that the types of LHS and RHS are similar, but it may be
         --  a small record and the types on both sides may differ.
         --
         --  If we're dealing with elementary types, convert the RHS to the
         --  type of the LHS.  Otherwise, convert the type of the LHS to be
         --  a reference to the type of the RHS.

         if Is_Elementary_Type (LHS_TE) then
            RHS := Convert (RHS, LHS_TE);
         else
            LHS := Convert_Ref (LHS, RHS_TE);
         end if;

         --  Now do the assignment.  We could call Emit_Assignment, but
         --  we've already done almost all of the work above.

         Store (RHS, LHS);
      end Write_Back;

   begin  -- Start of processing for Emit_Call

      if Direct_Call then
         Subp := Entity (Subp);
      end if;

      --  See if this is an instrinsic subprogram that we handle.  We're
      --  done if so.

      if Direct_Call and then Is_Intrinsic_Subprogram (Subp) then
         Result := Emit_Intrinsic_Call (N, Subp);
         if Present (Result) then
            return Result;
         end if;
      end if;

      LLVM_Func := Emit_LValue (Subp);
      if This_Adds_S_Link then
         S_Link    := Get (LLVM_Func, Reference_To_Activation_Record);
         LLVM_Func := Get (LLVM_Func, Reference);
      end if;

      --  Add a pointer to the location of the return value if the return
      --  type is of dynamic size.

      if RK = Return_By_Parameter then
         Args (In_Idx) :=
           Allocate_For_Type (Return_Typ, Return_Typ, Subp, Name => "return");
         In_Idx        := In_Idx + 1;
      end if;

      Param  := First_Formal_With_Extras (Subp_Typ);
      Actual := First_Actual (N);
      while Present (Actual) loop

         declare
            TE  : constant Entity_Id       := Full_Etype (Param);
            PK  : constant Param_Kind      := Get_Param_Kind (Param);
            R   : constant GL_Relationship := Relationship_For_PK (PK, TE);
            Arg : GL_Value;

         begin
            --  We don't want to get confused between LValues from
            --  a previous parameter when getting positions and
            --  sizes of another, so clear the list.

            Clear_LValue_List;
            if PK_Is_In (PK) then

               --  We have two cases: if the param isn't passed
               --  indirectly, convert the value to the parameter's type.
               --  If it is, then convert the pointer to being a pointer
               --  to the parameter's type.

               if PK_Is_Reference (PK) then
                  Arg := Emit_LValue (Actual);
                  if PK = Foreign_By_Reference then
                     Arg := Ptr_To_Relationship (Get (Arg, R), TE, R);
                  else
                     Arg := Convert_Ref (Arg, TE);
                  end if;
               else
                  Arg := Emit_Convert_Value (Actual, TE);
               end if;

               Args (In_Idx) := Arg;
               In_Idx        := In_Idx + 1;
            end if;

            --  For out and in out parameters, we need to evaluate the
            --  expression before the call (see, e.g., c64107a) into an
            --  LValue and use that after the return.  We look through any
            --  conversions here.

            if PK_Is_Out (PK) then
               Out_LHSs (Out_Idx) := Emit_LValue (Strip_Conversions (Actual));
               Out_Idx            := Out_Idx + 1;
            end if;
         end;

         Next_Actual (Actual);
         Next_Formal_With_Extras (Param);
         pragma Assert (No (Actual) = No (Param));
      end loop;

      --  Set the argument for the static link, if any

      if This_Adds_S_Link then
         Args (In_Idx) := S_Link;
      end if;

      --  Now we handle the result.  It may be the return type of a function,
      --  in which case we return it, one or more out parameters, or both.
      --  We may also have used the first parameter to pass an address where
      --  our value was returned.

      case LRK is
         when Void =>
            Call (LLVM_Func, Args);

         when Subprog_Return =>
            if RK = RK_By_Reference then
               return Call_Ref (LLVM_Func, Return_Typ, Args);
            else
               return Call (LLVM_Func, Return_Typ, Args);
            end if;

         when Out_Return =>

            --  Write back the single out parameter to our saved LHS

            Write_Back
              (Out_LHSs (1), Call (LLVM_Func, Full_Etype (Out_Param), Args));

         when Struct_Out | Struct_Out_Subprog =>
            Actual_Return := Call_Struct (LLVM_Func, Return_Typ, Args);

            --  First extract the return value (possibly returned by-ref)

            Ret_Idx := 0;
            if LRK = Struct_Out_Subprog then
               if RK = RK_By_Reference then
                  Result := Extract_Value_To_Ref (Return_Typ, Actual_Return,
                                                  unsigned (Ret_Idx));
               else
                  Result := Extract_Value (Return_Typ, Actual_Return,
                                           unsigned (Ret_Idx));
               end if;

               Ret_Idx := Ret_Idx + 1;
            end if;

            --  Now write back any out parameters

            Out_Idx := 1;
            while Present (Out_Param) loop
               Write_Back (Out_LHSs (Out_Idx),
                           Extract_Value (Full_Etype (Out_Param),
                                          Actual_Return, unsigned (Ret_Idx)));
               Ret_Idx := Ret_Idx + 1;
               Out_Idx := Out_Idx + 1;
               Next_Out_Param (Out_Param);
            end loop;
      end case;

      if RK = Return_By_Parameter then
         return Convert_Ref (Args (1), Our_Return_Typ);
      else
         return Result;
      end if;

   end Emit_Call;

   --------------------------
   -- Emit_Subprogram_Decl --
   --------------------------

   function Emit_Subprogram_Decl (N : Node_Id) return GL_Value is
      Def_Ident : constant Entity_Id := Defining_Entity (N);
   begin
      if not Has_Value (Def_Ident) then
         Set_Value (Def_Ident, Create_Subprogram (Def_Ident));
      end if;

      return Get_Value (Def_Ident);
   end Emit_Subprogram_Decl;

   ------------------------
   --  Create_Subprogram --
   ------------------------

   function Create_Subprogram (Def_Ident : Entity_Id) return GL_Value is
      Subp_Type   : constant Type_T      := Create_Subprogram_Type (Def_Ident);
      Subp_Name   : constant String      := Get_Ext_Name (Def_Ident);
      Actual_Name : constant String      :=
        (if Is_Compilation_Unit (Def_Ident)
           and then No (Interface_Name (Def_Ident))
         then "_ada_" & Subp_Name else Subp_Name);
      LLVM_Func   : GL_Value             := Get_Dup_Global_Value (Def_Ident);
      RK          : constant Return_Kind := Get_Return_Kind (Def_Ident);
      Return_Typ  : constant Entity_Id   := Full_Etype (Def_Ident);
      Param_Num   : Natural              := 0;
      Formal      : Entity_Id;

   begin
      --  If we've already seen this function name before, verify that we
      --  have the same type.  Convert it to it if not.

      if Present (LLVM_Func)
        and then Type_Of (LLVM_Func) /= Pointer_Type (Subp_Type, 0)
      then
         LLVM_Func := G_From (Pointer_Cast (IR_Builder,
                                            LLVM_Value (LLVM_Func),
                                            Pointer_Type (Subp_Type, 0),
                                            Subp_Name),
                              LLVM_Func);
      elsif No (LLVM_Func) then
         LLVM_Func := Add_Function (Actual_Name,
                                    Subp_Type, Full_Etype (Def_Ident));
         --  Define the appropriate linkage

         if not In_Extended_Main_Code_Unit (Def_Ident) then
            Set_Linkage (LLVM_Func, External_Linkage);
         elsif not Is_Public (Def_Ident) then
            Set_Linkage (LLVM_Value (LLVM_Func), Internal_Linkage);
         end if;

         Set_Dup_Global_Value (Def_Ident, LLVM_Func);

         --  Now deal with function and parameter attributes
         --  ??? We don't handle most return value attributes yet.  noalias
         --  is an important one.

         if No_Return (Def_Ident) then
            Set_Does_Not_Return (LLVM_Func);
         end if;

         if RK = Return_By_Parameter then
            Add_Dereferenceable_Attribute (LLVM_Func, Param_Num, Return_Typ);
            Add_Noalias_Attribute         (LLVM_Func, Param_Num);
            Add_Nocapture_Attribute       (LLVM_Func, Param_Num);
            Param_Num := Param_Num + 1;
         end if;

         Formal := First_Formal_With_Extras (Def_Ident);
         while Present (Formal) loop
            declare
               PK : constant Param_Kind := Get_Param_Kind (Formal);
               TE : constant Entity_Id  := Full_Etype (Formal);
               DT : constant Entity_Id  :=
                 (if   Is_Access_Type (TE) then Full_Designated_Type (TE)
                  else Empty);

            begin
               if PK = Activation_Record then
                  Add_Dereferenceable_Attribute (LLVM_Func, Param_Num, DT);
                  Add_Noalias_Attribute         (LLVM_Func, Param_Num);
                  Add_Nocapture_Attribute       (LLVM_Func, Param_Num);
                  Add_Readonly_Attribute        (LLVM_Func, Param_Num);
                  if Has_Foreign_Convention (Def_Ident) then
                     Add_Nest_Attribute         (LLVM_Func, Param_Num);
                  end if;

               elsif PK_Is_Reference (PK)
                 and then (not Is_Unconstrained_Array (TE)
                             or else PK = Foreign_By_Reference)
               then
                  --  Technically, we can take 'Address of a parameter
                  --  and put the address someplace, but that's undefined,
                  --  so we can set this as nocapture.

                  Add_Dereferenceable_Attribute (LLVM_Func, Param_Num, TE);
                  Add_Noalias_Attribute         (LLVM_Func, Param_Num);
                  Add_Nocapture_Attribute       (LLVM_Func, Param_Num);
                  if Ekind (Formal) = E_In_Parameter then
                     Add_Readonly_Attribute     (LLVM_Func, Param_Num);
                  end if;

               elsif PK_Is_In (PK) and then Is_Access_Type (TE)
                 and then not Is_Unconstrained_Array (DT)
                 and then Ekind (DT) /= E_Subprogram_Type
               then
                  if Can_Never_Be_Null (TE) then
                     Add_Dereferenceable_Attribute (LLVM_Func, Param_Num, DT);
                  else
                     Add_Dereferenceable_Or_Null_Attribute
                       (LLVM_Func, Param_Num, DT);
                  end if;
               end if;

               if PK_Is_In (PK) then
                  Param_Num := Param_Num + 1;
               end if;

               Next_Formal_With_Extras (Formal);
            end;
         end loop;

      end if;

      Set_Value (Def_Ident, LLVM_Func);

      if Subp_Name = "ada_main___elabb" then
         Ada_Main_Elabb := LLVM_Func;
      end if;

      return LLVM_Func;
   end Create_Subprogram;

   --------------
   -- Subp_Ptr --
   --------------

   function Subp_Ptr (N : Node_Id) return GL_Value is
   begin
      if Nkind (N) = N_Null then
         return Const_Null (Standard_A_Char);
      else
         return Load
           (GEP (Standard_A_Char, Emit_LValue (N),
                 (1 => Const_Null_32, 2 => Const_Null_32)));

      end if;
   end Subp_Ptr;

   ----------------
   -- Enter_Subp --
   ----------------

   procedure Enter_Subp (Func : GL_Value) is
   begin
      Current_Func         := Func;
      Activation_Rec_Param := No_GL_Value;
      Return_Address_Param := No_GL_Value;
      Entry_Block_Allocas  := No_Position_T;
      Position_Builder_At_End (Create_Basic_Block ("entry"));
   end Enter_Subp;

   ----------------
   -- Leave_Subp --
   ----------------

   procedure Leave_Subp is
   begin
      Current_Func := No_GL_Value;
   end Leave_Subp;

   -------------------
   -- Library_Level --
   -------------------

   function Library_Level return Boolean is
     (Current_Func = No_GL_Value);

   ------------------------
   -- Create_Basic_Block --
   ------------------------

   function Create_Basic_Block (Name : String := "") return Basic_Block_T is
   begin
      return Append_Basic_Block_In_Context
        (Context, LLVM_Value (Current_Func), Name);
   end Create_Basic_Block;

   ----------------
   -- Initialize --
   ----------------

   procedure Initialize is
   begin
      Register_Global_Name ("__gnat_free");
      Register_Global_Name ("__gnat_malloc");
      Register_Global_Name ("memcmp");
   end Initialize;

end GNATLLVM.Subprograms;
