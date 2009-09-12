#!/usr/bin/ruby

class Unit
  def initialize(name=nil)
    @name = name
  end
  def name
    if @name then @name else super.to_s end
  end
  def ==(other)
    __id__==other.__id__
  end
end
class BiasUnit < Unit
end
class IdentityUnit < Unit
  def formula_name; ""; end
  def activation_func(a); a; end
  def divback(z); "1"; end
end
class SoftMaxUnit < IdentityUnit
end
class TanhUnit < Unit
  def formula_name; "tanh"; end
  def activation_func(a); "Math.tanh(#{a})"; end
  def divback(z); "(1-#{z}**2)"; end
end
class SigUnit < Unit
  def formula_name; "sig"; end
  def activation_func(a); "1.0/(1+Math.exp(-(#{a})))"; end
  def divback(z); "(_z=#{z})*(1-_z)"; end
end


# error function
module ErrorFunction
  SquaresSum = Proc.new do |y, t|
    e = 0
    y.each_with_index do |y_i, i|
      e += (y_i - t[i]) ** 2
    end
    e / 2
  end
  CrossEntropy = Proc.new do |y, t|
    e = 0
    y.each_with_index do |y_i, i|
      e -= t[i] * Math.log(y_i) + (1 - t[i]) * Math.log(1 - y_i)
    end
    e
  end
  SoftMax = Proc.new do |y, t|
    e = 0
    y.each_with_index do |y_i, i|
      e -= t[i] * Math.log(y_i)
    end
    e
  end
end

# gradient of error function
module Gradient
  EPSILON = 0.0001

  NumericalDiff = Proc.new do |network, x, t|
    g = []
    network.weights.size.times do |index|
      network.weights.parameters[index] += EPSILON
      e1 = network.error_function(x, t)
      network.weights.back_to_orig

      network.weights.parameters[index] -= EPSILON
      e2 = network.error_function(x, t)
      network.weights.back_to_orig

      g << (e1 - e2) / (2 * EPSILON)
    end
    g
  end

  BackPropagate = Proc.new do |network, x, t|
    # calculate z of all units
    z = network.calculate_z(x)

    # calculate delta(error) of output units
    delta = network.calculate_delta(z, t)

    # calculate difference of all weights
    network.calculate_back_gradient(z, delta)
  end
end

# weight parameters
class Weights
  def initialize
    @orig_parameters = @parameters = []
    @from_units = []
    @to_units = []
    @map_to_index = Hash.new
    @map_from_index = Hash.new
  end
  def append(from, to)
    @map_to_index[to] ||= []
    @map_to_index[to] << @parameters.length
    @map_from_index[from] ||= []
    @map_from_index[from] << @parameters.length

    @parameters << normrand(0, 1)
    @from_units << from
    @to_units << to
  end
  def normrand(m=0, s=1)
    r=0
    12.times{ r+=rand() }
    (r - 6) * s + m
  end
  def in_units(out_unit)
    in_list = Hash.new
    @map_to_index[out_unit].each do |i|
      in_list[@from_units[i]] = @parameters[i]
    end
    in_list
  end
  def each_in_units(out_unit)
    @map_to_index[out_unit].each do |i|
      yield @from_units[i], i
    end
  end
  def each_out_units(in_unit)
    @map_from_index[in_unit].each do |i|
      yield @to_units[i], i
    end
  end
  def out_units(in_unit)
    out_list = Hash.new
    @map_from_index[in_unit].each do |i|
      out_list[@to_units[i]] = @parameters[i]
    end
    out_list
  end
  def back_to_orig
    @parameters = @orig_parameters
  end
  def size
    @parameters.length
  end
  def descent(eta, grad)
    @parameters = []
    @orig_parameters.each_with_index do |w_i, i|
      @parameters << w_i - eta * grad[i]
    end
    @orig_parameters = @parameters
  end
  def parameters
    @parameters
  end
  def each_from_to
    @from_units.each_with_index do |from, i|
      yield from, @to_units[i], i
    end
  end
  def dump
    d = Hash.new
    @to_units.each_with_index do |unit, i|
      d[unit] ||= []
      if @from_units[i].instance_of?(BiasUnit)
        d[unit] << "#{@parameters[i]}"
      else
        d[unit] << "#{@parameters[i]} * #{@from_units[i].name}"
      end
    end
    d.each do |unit, formula|
      puts "#{unit.name} <- #{unit.formula_name}( #{formula.join(" + ")} );".gsub('+ -','- ')
    end
  end
end


# neural network
class Network
  def initialize(opt={})
    @error_func = opt[:error_func] || ErrorFunction::SquaresSum
    @gradient = opt[:gradient] || Gradient::BackPropagate
    @units = []
    @unit_index = Hash.new
    @weights = Weights.new
    @in_list = []
    @out_list = []
    @backward_prop = nil
    @softmax_output = false
  end

  def append_unit(list)
    list.each do |unit|
      unless @unit_index.key?(unit)
        @unit_index[unit] = @units.length
        @units << unit
      end
    end
  end

  def link(from_list, to_list)
    append_unit from_list
    append_unit to_list
    from_list.each do |from|
      to_list.each do |to|
        @weights.append from, to
      end
    end
  end

  def in=(in_list)
    @in_list = in_list
    append_unit in_list
  end

  # set output units
  def out=(out_list)
    @out_list = out_list
    n_softmax = 0
    out_list.each do |unit|
      raise "There is a output unit without link." unless @units.include?(unit)
      n_softmax += 1 if unit.instance_of?(SoftMaxUnit)
    end
    if n_softmax == out_list.length
      @softmax_output = true
    elsif n_softmax > 0
      raise "All output units must be SoftMaxUnit"
    end

    # code generator
    generated_forward_prop
    generate_calculate_delta
  end

  def arrange_forward
    calcurated = Hash.new
    @units.each do |unit|
      calcurated[unit] = 1 if unit.instance_of?(BiasUnit) || @in_list.include?(unit)
    end

    arranged = []
    while calcurated.size < @units.length
      advance = false
      @units.each do |unit|
        next if calcurated.key?(unit)
        in_list = @weights.in_units(unit)
        if in_list.keys.all?{|z| calcurated.key?(z)}
          arranged << unit
          calcurated[unit] = 1
          advance = true
        end
      end
      raise "There is a not-calcurable unit." unless advance
    end

    arranged
  end

  def generated_forward_prop
    proc = []
    proc << "Proc.new do |network, params|"
    proc << "w_=network.weights.parameters"
    proc << "r_=Array.new(#{@units.length})"

    @units.each_with_index do |u, i|
      proc << "r_[#{i}]=1" if u.instance_of?(BiasUnit)
    end

    @in_list.each_with_index do |unit, i|
      proc << "r_[#{@unit_index[unit]}]=#{unit.name}=params[#{i}]"
    end

    arrange_forward.each do |unit|
      forms = []
      @weights.each_in_units(unit) do |u, i|
        if u.instance_of?(BiasUnit)
          forms << "w_[#{i}]"
        else
          forms << "w_[#{i}]*#{u.name}"
        end
      end
      proc << "r_[#{@unit_index[unit]}]=#{unit.name}=#{unit.activation_func(forms.join("+"))}"
    end

    if @softmax_output
      proc << "max_a=[#{@out_list.map{|unit| unit.name}.join(',')}].max"
      proc << "sum_exp_a=0"
      @out_list.each do |unit|
        proc << "e_#{unit.name}=Math.exp(#{unit.name}-max_a)"
        proc << "sum_exp_a+=e_#{unit.name}"
      end
      @out_list.each do |unit|
        proc << "r_[#{@unit_index[unit]}]=e_#{unit.name}/sum_exp_a"
      end
    end

    proc << "r_"
    proc << "end"
    #puts proc.join("\n")
    @forward_prop = eval(proc.join("\n"))

    # extract output units
    proc = []
    proc << "Proc.new do |z|"
    proc << "z[#{@unit_index[@out_list[0]]},#{@out_list.length}]"
    proc << "end"
    #puts proc.join("\n")
    @extract_output = eval(proc.join("\n"))
  end

  def generate_calculate_delta
    proc = []
    proc << "Proc.new do |network, z, t|"
    proc << "w_=network.weights.parameters"
    proc << "d_=Array.new(#{@units.length})"

    @out_list.each_with_index do |unit, i|
      proc << "d_[#{@unit_index[unit]}]=z[#{@unit_index[unit]}]-t[#{i}]"
    end

    backward_prop.each do |unit|
      sum = []
      @weights.each_out_units(unit) do |out_unit, i|
        sum << "w_[#{i}]*d_[#{@unit_index[out_unit]}]"
      end
      idx = @unit_index[unit]
      proc << "d_[#{idx}]=#{unit.divback("z[#{idx}]")}*(#{sum.join('+')})"
    end
    proc << "d_"
    proc << "end"
    #puts proc.join("\n")
    @calculate_delta = eval(proc.join("\n"))

    proc = []
    proc << "Proc.new do |network, z, d|"
    proc << "g=Array.new(#{@weights.size})"
    @weights.each_from_to do |from, to, i|
      proc << "g[#{i}]=d[#{@unit_index[to]}]*z[#{@unit_index[from]}]"
    end
    proc << "g"
    proc << "end"
    #puts proc.join("\n")
    @calculate_back_gradient = eval(proc.join("\n"))
  end

  def arrange_backward
    calcurated = Hash.new
    @out_list.each do |unit|
      calcurated[unit] = 1
    end

    arranged = []
    while true
      advance = false
      @units.each do |unit|
        next if calcurated.key?(unit) || unit.instance_of?(BiasUnit) || @in_list.include?(unit)
        out_list = @weights.out_units(unit)
        if out_list.keys.all?{|z| calcurated.key?(z)}
          arranged << unit
          calcurated[unit] = 1
          advance = true
        end
      end
      break unless advance
    end

    arranged
  end

  def backward_prop
    @backward_prop = arrange_backward unless @backward_prop
    @backward_prop
  end

  def apply(*params)
    calculate_z(params, true)
  end

  def calculate_z(params, output_unit_array=false)
    raise "not equal # of parameters to # of input units" if params.length != @in_list.length

    z = @forward_prop.call(self, params)

    if output_unit_array
      @extract_output.call(z)
    else
      z
    end
  end

  def calculate_back_gradient(z, delta)
    @calculate_back_gradient.call(self, z, delta)
  end

  def calculate_delta(z, t)
    @calculate_delta.call(self, z, t)
  end

  def error_function(x, t)
    @error_func.call(apply(*x), t)
  end

  def gradient_E(x, t)
    @gradient.call(self, x, t)
  end

  def weights
    @weights
  end
end


