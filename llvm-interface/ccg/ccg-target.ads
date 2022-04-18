------------------------------------------------------------------------------
--                              C C G                                       --
--                                                                          --
--                     Copyright (C) 2022, AdaCore                     --
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

package CCG.Target is

   --  This package contains target information about the C compiler used
   --  and how to format and generate code.

   C_Indent     : Integer := 2;
   --  Number of characters to indent at each level

   Warns_Parens : Boolean := True;
   --  True if this C compiler will issue warning in cases where the
   --  precedence is correct but looks suspicious.

   Always_Brace : Boolean := False;
   --  True if we're to always write C lexical blocks using braces even
   --  if they're only a single line.

   Max_Depth    : Integer := (80 / 2) / (2 * C_Indent);
   --  Maximum allowable nesting depth of constructs

   Version      : Integer := 1990;
   --  C standard for which we're to write output

   procedure Set_C_Parameter (S : String);
   --  S is of the form "name=value". Use it to set parameter "name" to "value"

end CCG.Target;
