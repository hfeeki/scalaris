% @copyright 2010-2011 Zuse Institute Berlin

%   Licensed under the Apache License, Version 2.0 (the "License");
%   you may not use this file except in compliance with the License.
%   You may obtain a copy of the License at
%
%       http://www.apache.org/licenses/LICENSE-2.0
%
%   Unless required by applicable law or agreed to in writing, software
%   distributed under the License is distributed on an "AS IS" BASIS,
%   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%   See the License for the specific language governing permissions and
%   limitations under the License.

%% @author Nico Kruber <kruber@zib.de>
%% @doc    Common types and function specs for ring maintenance implementations.
%% @end
%% @version $Id$

-ifdef(with_export_type_support).
-export_type([state/0, custom_message/0]).
-endif.

-export([init/3, on/2,
         zombie_node/2, crashed_node/2,
         new_pred/2, new_succ/2,
         leave/1, remove_pred/3, remove_succ/3,
         update_node/2,
         get_neighbors/1,
         get_web_debug_info/1,
         check_config/0,
         unittest_create_state/1]).
