module Fulfillment
  class PickList
    def self.add(line_item)
      new.push(line_item)
    end

    def push(line_item)
      (@items ||= []) << line_item
    end
  end
end
