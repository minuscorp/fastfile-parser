require 'json'
require 'parser'
require 'parser/current'
require 'unparser'

# opt-in to most recent AST format:
# Parser::Builders::Default.emit_lambda = true
# Parser::Builders::Default.emit_procarg0 = true

# Parse a Fastfile and convert it to JSON data
module Fastlane
  class FastfileParser
    attr_accessor :path
    attr_accessor :content
    attr_accessor :tree
    attr_accessor :raw_tree

    def initialize(path: nil)
      self.path = path
      self.content = File.read(path)
      self.tree = {}
      self.raw_tree = ::Parser::CurrentRuby.parse(self.content)
      @current_description = []

      self.parse_children(self.raw_tree)
    end

    # @return value looks like the following
    #   ["no_platform_lane_name", "ios beta", "android lane1", "android lane2"]
    def available_lanes
      lanes = []
      self.tree.each do |platform, value|
        value.each do |lane_name, lane_content|
          lanes << [platform, lane_name].compact.join(" ")
        end
      end
      lanes.delete_if { |l| l.to_s.length == 0}
      return lanes
    end

    def parse_children(node)
      if node.children.any? { |current_node| current_node.is_a?(Parser::AST::Node) }
        if node.type == :send
          parse_node(node)
        else
          node.children.each do |current_node|
            parse_node(current_node)
          end
        end
      else
        parse_node(node)
      end
    end

    def parse_node(current_node)
      return unless current_node.kind_of?(Parser::AST::Node)

      if current_node.type == :send # method
        method_name = current_node.children[1]
        parameters = current_node.children[2].children if current_node.children[2]

        if parameters && parameters.first && parameters.first.kind_of?(Parser::AST::Node)
          new_parameters = {}
          parameters.each do |current_parameter|
            parameter_key = current_parameter.children[0].children.last

            if current_parameter.type == :pair
              # Boolean values are always an exception in Ruby
              if current_parameter.children[1].type == :true
                new_parameters[parameter_key] = true # actual boolean, not a symbol
              elsif current_parameter.children[1].type == :false
                new_parameters[parameter_key] = false # actual boolean, not a symbol
              else
                new_parameters[parameter_key] = current_parameter.children[1].children.last
              end
            end
          end
          parameters = new_parameters
        elsif parameters
          parameters = parameters.first
        end

        if method_name == :desc
          @current_description << parameters
        else
          access_current_node[:actions] << {
            action: method_name,
            parameters: parameters
          }
        end
      elsif current_node.type == :block # lane/platform
        method_name = current_node.children[0].children[1]
        parameters = current_node.children[1]
        block_node = current_node.children[2]

        if method_name == :before_all
          @current_lane = :_before_all_block_
          parse_children(block_node)
          @current_lane = nil
        elsif method_name == :after_all
          @current_lane = :_after_all_block_
          parse_children(block_node)
          @current_lane = nil
        elsif method_name == :error
          @current_lane = :_error_block_
          parse_children(block_node)
          @current_lane = nil
        elsif method_name == :lane || method_name == :private_lane
          lane_name = current_node.children[0].children[2].children.last
          @current_lane = lane_name
          access_current_node[:description] = @current_description
          access_current_node[:private] = method_name == :private_lane
          @current_description = []
          parse_children(block_node) if block_node
          @current_lane = nil
        elsif method_name == :platform
          platform_name = current_node.children[0].children[2].children.last
          @current_platform = platform_name
          parse_children(block_node) if block_node.type == :block
          parse_children(block_node) if block_node.type == :begin # this is different for nested blocks with no methods inbetween
          @current_platform = nil
        else
          access_current_node[:actions] << {
            advancedCode: Unparser.unparse(current_node)
          }
        end
      else
        access_current_node[:actions] << {
          advancedCode: Unparser.unparse(current_node)
        }
      end
    end

    def access_current_node
      self.tree[@current_platform] ||= {}
      self.tree[@current_platform][@current_lane] ||= {
        description: [],
        actions: []
      }
      return self.tree[@current_platform][@current_lane]
    end

    def print
      STDOUT.puts JSON.pretty_generate(self.tree)
    end
  end
end

# Target Format
# {
#   "ios": {
#     "beta": {
#       "description": "My description",
#       "actions": [
#         {
#           "action": "gym",
#           "parameters": {
#             "scheme": "Example"
#           }
#         }
#       ]
#     }
#   }
# }
