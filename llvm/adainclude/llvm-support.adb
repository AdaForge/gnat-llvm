pragma Style_Checks (Off);
pragma Warnings (Off, "*is already use-visible*");
pragma Warnings (Off, "*redundant with clause in body*");

with Interfaces.C;         use Interfaces.C;
pragma Unreferenced (Interfaces.C);
with Interfaces.C.Strings; use Interfaces.C.Strings;pragma Unreferenced (Interfaces.C.Strings);

package body LLVM.Support is

   function Load_Library_Permanently
     (Filename : String)
      return Boolean
   is
      Filename_Array  : aliased char_array := To_C (Filename);
      Filename_String : constant chars_ptr := To_Chars_Ptr (Filename_Array'Unchecked_Access);
   begin
      return Load_Library_Permanently_C (Filename_String) /= 0;
   end Load_Library_Permanently;

   function Search_For_Address_Of_Symbol
     (symbol_Name : String)
      return System.Address
   is
      symbol_Name_Array  : aliased char_array := To_C (symbol_Name);
      symbol_Name_String : constant chars_ptr := To_Chars_Ptr (symbol_Name_Array'Unchecked_Access);
   begin
      return Search_For_Address_Of_Symbol_C (symbol_Name_String);
   end Search_For_Address_Of_Symbol;

   procedure Parse_Command_Line_Options
     (argc     : int;
      argv     : System.Address;
      Overview : String)
   is
      Overview_Array  : aliased char_array := To_C (Overview);
      Overview_String : constant chars_ptr := To_Chars_Ptr (Overview_Array'Unchecked_Access);
   begin
      Parse_Command_Line_Options_C (argc, argv, Overview_String);
   end Parse_Command_Line_Options;

   procedure Add_Symbol
     (symbol_Name  : String;
      symbol_Value : System.Address)
   is
      symbol_Name_Array  : aliased char_array := To_C (symbol_Name);
      symbol_Name_String : constant chars_ptr := To_Chars_Ptr (symbol_Name_Array'Unchecked_Access);
   begin
      Add_Symbol_C (symbol_Name_String, symbol_Value);
   end Add_Symbol;

end LLVM.Support;
