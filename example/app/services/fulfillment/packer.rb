module Fulfillment
  class Packer
    # Reaching into Billing's internals from outside the namespace. Every
    # constant of a domain that outside code names is a promise the domain has
    # to keep once it lives behind a network call.
    def pack(order)
      return if Billing::Invoice.where(order: order).none?

      order.line_items.map { |line_item| pick(line_item) }
    end

    def pick(line_item)
      PickList.add(line_item)
    end
  end
end
