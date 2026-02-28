class ZipfianGenerator
  def initialize(min, max, zipfian_constant = 0.99)
    @min = min
    @max = max
    @items = max - min + 1
    @zipfian_constant = zipfian_constant
    @alpha = 1.0 / (1.0 - zipfian_constant)
    @zetan = zeta(@items)
    @eta = (1.0 - (2.0 / @items)**(1.0 - zipfian_constant)) / (1.0 - zeta(2) / @zetan)
  end

  def next_val
    u = rand
    uz = u * @zetan
    if uz < 1.0
      return @min
    end
    if uz < 1.0 + (0.5**@zipfian_constant)
      return @min + 1
    end
    @min + (@items * (@eta * u - @eta + 1.0)**@alpha).to_i
  end

  private

  def zeta(n)
    sum = 0.0
    (1..n).each do |i|
      sum += 1.0 / (i**@zipfian_constant)
    end
    sum
  end
end
generator = ZipfianGenerator.new(0, 1_000_000)
puts generator.next_val
