#! /usr/bin/ruby

module Utilities
  def self.deep_copy(item)
    Marshal.load(Marshal.dump(item))
  end
end

# Defines what a working memory element contains
WorkingMemoryElement = Struct.new(:identifier, :field, :value) do
  def inspect
    "(#{identifier} #{field} #{value})"
  end
end

# Defines an unbound variable in a set of production conditions
Variable = Struct.new(:identifier) do

end

# Contains all definitions for the alpha network
module Alpha

  # Base class for all alpha nodes, including the root node, condition nodes and
  # memory nodes
  #
  # Fields:
  # * children: List of nodes to pass on the wme
  class Node
    attr_accessor :children

    def initialize(children: [])
      @children = children
    end
  end

  # Defines a root alpha node which alwways activates all of its children
  #
  # Fields:
  # * children: List of nodes to pass on the wme
  class Root < Node
    def initialize(children: [])
      super(children: children)
    end

    # Activates this node, propagating the wme to all the children
    def activate(wme)
      self.children.each do |child|
        child.activate(wme)
      end
    end

    def inspect
      "Alpha::Root(children: #{children.inspect})"
    end
  end

  # Defines a comparison node in the alpha network. These nodes check if one of
  # the fields of a working memory element (either identifier, field or value)
  # matches to a given value.
  #
  # Fields:
  #   * wme_field: What field of the working memory element the node tests
  #
  #   * operator: Operation to perform when matching the wme field value to the
  #   given value. Defaults to straight equality checking.
  #
  #   * value: Value to compare the wme field value to
  #
  #   * children: List of nodes to pass on the wme if the test is successful
  class Condition < Node
    attr_accessor :field
    attr_accessor :operator
    attr_accessor :value
    attr_accessor :raw_operator

    def initialize(field, operator, value, children: [])
      super(children: children)
      @field = field
      @value = value
      @raw_operator = operator
      @operator = operator.to_proc
    end

    # Activates this node, asking it to evaluate the condition and propagate the
    # wme if the condition succeeds
    def activate(wme)
      if (self.operator.call(wme[self.field], self.value))
        self.children.each do |child|
          child.activate(wme)
        end
      end
    end

    def inspect
      "Alpha::Condition(condition: #{self.field} #{self.raw_operator} #{self.value}, children: #{children.inspect})"
    end
  end

  # Defines an alpha memory node, which stores working memory elements which have
  # passed one or more alpha tests
  #
  # Fields:
  # * items: List of wme's already contained in this memory
  # * children: List of nodes to pass on the wme
  class Memory < Node
    attr_accessor :items

    def initialize(items: [], children: [])
      super(children: children)
      @items = items
    end

    # Activates this node, storing the wme in the memory and propagating the
    # changes to all the children. Children are always beta nodes, so we must
    # alpha-activate those.
    def activate(wme)
      self.items.push(wme).uniq
      self.children.each do |child|
        child.alpha_activate(wme)
      end
    end

    def inspect
      "Alpha::Memory(items: #{self.items.inspect}, children: #{self.children.inspect})"
    end
  end

end

# Contains all definitions for the beta network
module Beta

  # Base class for all the beta network nodes
  #
  # Fields:
  # * children: List of nodes that depend on the output of this node
  class Node
    attr_accessor :children

    def initialize(children: [])
      @children = children
    end
  end

  # Defines a memory node, which stores lists of partial matches
  #
  # Fields:
  # * children: List of nodes that depend on the output of this node
  # * items: List of tokens in this memory. A token is an ordered list of wme's
  # that have matched a set of conditions, a partial match for a production
  # rule.
  class Memory < Node
    attr_accessor :items

    def initialize(children: [], items: [])
      super(children: children)
      @items = items
    end

    # Activates this memory node, adding a new token to the memory and notify
    # all children. Children are always beta nodes, so we must beta-activate them
    def beta_activate(token)
      self.items.push(token).uniq
      self.children.each do |child|
        child.beta_activate(token)
      end
    end

    def inspect
      "Beta::Memory(items: #{self.items.inspect}, children: #{self.children.inspect})"
    end
  end

  # Defines an adapter node that exposes an alpha memory node as a beta memory
  # node
  #
  # Fields:
  # * children: List of nodes that depend on the output of this node
  # * items: List of tokens in this memory. A token is an ordered list of wme's
  # that have matched a set of conditions, a partial match for a production
  # rule.
  class AlphaMemoryAdapter < Node
    attr_accessor :items

    def initialize(children: [], items: [])
      super(children: children)
      @items = items
    end

    def alpha_activate(wme)
      self.items.push([wme]).uniq
      self.children.each do |child|
        child.beta_activate([wme])
      end
    end

    def inspect
      "Beta::Adapter(items: #{self.items.inspect}, children: #{self.children.inspect})"
    end
  end

  # Defines a join node in the beta network, which resolves variable binding
  # references in conditions
  #
  # Fields:
  # * children: List of nodes that depend on the output of this node
  # * beta_memory: Parent beta memory that works as the left parent of this node
  # * alpha_memory: Parent alpha memory that works as the right parent of this node
  # * tests: List of JoinNode::Test instances which describes what fields to
  # compare in a join operation, and which operator to compare with
  class Join < Node
    # Contains all the data that's necessary for performing a test on a join node
    #
    # Fields:
    # * alpha_field: The name of the field to take from the alpha memory
    # elements to perform the comparison
    # * operator: The operator to use when comparing
    # * beta_index: The index of the working memory element in the token to compare to
    # * beta_field: The nae of the field to take from the beta memory element
    # to perform the comparison
    Test = Struct.new(:alpha_field, :operator, :beta_index, :beta_field) do
      def inspect
        "Test(alpha[#{alpha_field}] #{operator} beta[#{beta_index}][#{beta_field}])"
      end
    end

    attr_accessor :beta_memory
    attr_accessor :alpha_memory
    attr_accessor :tests

    def initialize(children: [], alpha_memory: nil, beta_memory: nil, tests: [])
      super(children: children)
      @alpha_memory = alpha_memory
      @beta_memory = beta_memory
      @tests = tests
    end

    def self.register(children: [], alpha_memory: nil, beta_memory: nil, tests: [])
      instance = self.new(children: children, alpha_memory: alpha_memory, beta_memory: beta_memory, tests: tests)
      alpha_memory.children.push(instance) if alpha_memory
      beta_memory.children.push(instance) if beta_memory
      instance
    end

    def alpha_activate(wme)
      self.beta_memory.items.each do |token|
        if self.test(token, wme)
          new_token = Utilities.deep_copy(token).push(wme)
          self.children.each do |child|
            child.beta_activate(new_token)
          end
        end
      end
    end

    def beta_activate(token)
      self.alpha_memory.items.each do |wme|
        if self.test(token, wme)
          new_token = Utilities.deep_copy(token).push(wme)
          self.children.each do |child|
            child.beta_activate(new_token)
          end
        end
      end
    end

    def test(token, wme)
      self.tests.each do |test|
        lhs = wme[test.alpha_field]
        rhs = token[test.beta_index][test.beta_field]
        operation = test.operator.to_proc

        if !operation.call(lhs, rhs)
          return false
        end
      end

      return true
    end

    def inspect
      "Beta::Join(#{self.tests.inspect}, children: #{self.children.inspect})"
    end
  end

  # Defines a leaf node that performs and action
  class Production
    attr_accessor :action
    attr_accessor :name

    def initialize(name, &action)
      @name = name
      @action = action
    end

    def beta_activate(token)
      self.action.call(name, token)
    end

    def inspect
      "Beta::Production(#{self.name})"
    end
  end
end

################################################################################
# Sample
################################################################################
# We are going to build a sample network for a very simple domain. We have
# building blocks that can be connected on either side and to the top and
# bottom with other blocks. Each block has a specific color.
#
# We are going to model a very simple production rule, which checks for two
# blocks, one on top of the other, to the left of a red block. Formally, we
# want to fire a message if the following conditions are met:
#
# c1: (<x> :on <y>)
# c2: (<y> :left_of <z>)
# c3: (<z> :color :red)
################################################################################

# First we define the action associated with this rule
action = Beta::Production.new("Block on block left to red") do |rule, facts|
  puts "Triggered action #{rule} with the following facts: #{facts.inspect}"
end

# First we define our network, built to match the production rule described
# above We want to build an alpha condition to detect wme's that have the :on
# attribute, and put that into an alpha memory. The c1 memory needs an adapter
# for beta memory since it's the first condition.
alpha_memory_c1_adapter = Beta::AlphaMemoryAdapter.new
alpha_memory_c1 = Alpha::Memory.new(children: [alpha_memory_c1_adapter])
alpha_c1 = Alpha::Condition.new(:field, :==, :on, children: [
  alpha_memory_c1
])

# We also want to detect wme's that have the :left_of attribute
alpha_memory_c2 = Alpha::Memory.new
alpha_c2 = Alpha::Condition.new(:field, :==, :left_of, children: [
  alpha_memory_c2
])


# Finally, for a more complex example, we want to match wme's that have both
# color attribute and value red, so we chain multiple conditions here
alpha_memory_c3 = Alpha::Memory.new
alpha_c3 = Alpha::Condition.new(:field, :==, :color, children: [
  Alpha::Condition.new(:value, :==, :red, children: [
    alpha_memory_c3
  ])
])

# Now for the beta part. We need to build a join node that will check unbound
# variable matches in conditions c1 and c2. For this, we need to adapt the
# memory for c1 into a beta memory, and connect that to a join node
beta_memory_c1_c2 = Beta::Memory.new
Beta::Join.register(
  beta_memory: alpha_memory_c1_adapter,
  alpha_memory: alpha_memory_c2,
  tests: [Beta::Join::Test.new(:identifier, :==, 0, :value)],
  children: [beta_memory_c1_c2],
)

# The last join checks the result of the previous c1^c2 join with c3. This is
# the final result, so we connect this join node to a production node
Beta::Join.register(
  beta_memory: beta_memory_c1_c2,
  alpha_memory: alpha_memory_c3,
  tests: [Beta::Join::Test.new(:identifier, :==, 1, :value)],
  children: [action]
)

# Finally, we build the rete network
rete = Alpha::Root.new(children: [alpha_c1, alpha_c2, alpha_c3])

# Next we need to define our working memory. We'll setup some facts here:
working_memory = [
  WorkingMemoryElement.new(:b1, :on, :b2),
  WorkingMemoryElement.new(:b1, :on, :b3),
  WorkingMemoryElement.new(:b1, :color, :red),
  WorkingMemoryElement.new(:b2, :on, :table),
  WorkingMemoryElement.new(:b2, :left_of, :b3),
  WorkingMemoryElement.new(:b2, :color, :blue),
  WorkingMemoryElement.new(:b3, :left_of, :b4),
  WorkingMemoryElement.new(:b3, :on, :table),
  WorkingMemoryElement.new(:b3, :color, :red),
]

# We feed the working memory to the rete, this will trigger the action
puts "Loading facts into working memory"
working_memory.each do |wme|
  rete.activate(wme)
end

puts ""
puts "Done, the network state is #{rete.inspect}"

