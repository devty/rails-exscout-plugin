module Shipping
  class RateQuote
    def self.for(shipment)
      new(shipment).cents
    end

    def initialize(shipment)
      @shipment = shipment
    end

    def cents
      1_000
    end
  end
end
