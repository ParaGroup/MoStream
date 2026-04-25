# ===------------------------------------------------------------------------=== #
#  This program is free software; you can redistribute it and/or modify it
#  under the terms of the GNU Lesser General Public License version 3 as
#  published by the Free Software Foundation.
#  
#  This program is distributed in the hope that it will be useful, but WITHOUT
#  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
#  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU Lesser General Public
#  License for more details.
#  
#  You should have received a copy of the GNU Lesser General Public License
#  along with this program; if not, write to the Free Software Foundation,
#  Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.
# ===------------------------------------------------------------------------=== #

# Green print
def print_green_color(text: String):
    print("\x1b[32m" + text + "\x1b[0m")

# Cyan print
def print_cyan_color(text: String):
    print("\x1b[36m" + text + "\x1b[0m")

# Red print
def print_red_color(text: String):
    print("\x1b[31m" + text + "\x1b[0m")

# Yellow print
def print_yellow_color(text: String):
    print("\x1b[33m" + text + "\x1b[0m")
