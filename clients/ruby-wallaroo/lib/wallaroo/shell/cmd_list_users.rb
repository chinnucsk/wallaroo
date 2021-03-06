# Copyright (c) 2012 Red Hat, Inc.
# cmd_set_user_role.rb:  Updates Wallaby roles for broker users.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

$SHELL_SECRET=ENV['WALLABY_SECRET']

module Wallaroo
  module Shell
    class ListUsers < Command
      # opname returns the operation name; for "wallaby foo", it
      # would return "foo".
      def self.opname
        "list-users"
      end
    
      # description returns a short description of this command, suitable 
      # for use in the output of "wallaby help commands".
      def self.description
        "Lists Wallaby roles for broker users."
      end
    
      def init_option_parser
        # Edit this method to generate a method that parses your command-line options.
        OptionParser.new do |opts|
          opts.banner = "Usage:  wallaby #{self.class.opname}\n#{self.class.description}"
    
          opts.on("-h", "--help", "displays this message") do
            puts @oparser
            exit
          end

          opts.on("-s", "--secret SECRET", "Wallaby secret key (takes precedence over WALLABY_SECRET in environment)") do |secret|
            @secret = secret
          end
        end
      end
    
      def ensure_args(*args)
        # ensure_args will be invoked after command-line argument
        # processing.  args will contain every argument passed to this
        # command (after any processed command-line options are removed),
        # minus any arguments removed by prior callbacks. It may include,
        # for example, input filenames.
        @secret ||= $SHELL_SECRET
        unless args.length == 0
          exit!(1, "this command does not accept arguments")
        end
      end
    
      register_callback :after_option_parsing, :ensure_args
    
      def act
        # This method is responsible for actually performing the work of
        # the command. It may read the @kwargs instance variable, which
        # should be a hash, and must return an integer, corresponding to
        # the exit code of the command.
    
        options = {}
        options["secret"] = @secret if @secret
        
        store.users(options).each do |k,v|
          puts "#{k}: #{v}"
        end
        return 0
      end
    end
  end
end
