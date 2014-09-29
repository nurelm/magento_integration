require 'json'

module MagentoIntegration
  class Order < Base
    
    def get_orders(since_time)
      complex_filter = Hash.new
      complex_filter['key'] = "updated_at"
      complex_filter['value'] = {
          :key => "from",
          :value => since_time
      }

      response = @soapClient.call :sales_order_list, {
        :filters => {
          'complex_filter' => [[complex_filter]]
        }
      }

      wombat_orders = Array.new

      orders = response.body

      magento_orders = convert_to_array(orders[:sales_order_list_response][:result][:item])

      magento_orders.each do |order|

        orderResponse = @soapClient.call :sales_order_info, { :order_increment_id => order[:increment_id] }

        order = orderResponse.body[:sales_order_info_response][:result]

        payments = Array.new

        total_payments = 0

        order_payments = convert_to_array(order[:payment])

        order_payments.each do |payment|
          if payment.has_key?('amount_paid')
            total_payments += payment.has_key?('amount_paid').to_f
          end
          payments.push({
            :number => payment[:payment_id],
            :status => (payment.has_key?('amount_paid') && (payment[:amount_ordered].to_f == payment[:amount_paid].to_f)) ? 'completed' : 'pending',
            :amount => (payment.has_key?('amount_paid')) ? payment[:amount_ordered].to_f : 0,
            :payment_method => payment[:method]
          })
        end

        orderTotal = {
          :item => order[:subtotal].to_f,
          :tax => order[:tax_amount].to_f + order[:shipping_tax_amount].to_f,
          :shipping => order[:shipping_amount].to_f,
          :payment => total_payments,
          :discount => order[:discount_amount].to_f,
          :order => order[:grand_total].to_f
        }
        orderTotal[:adjustments] = orderTotal[:tax] + orderTotal[:shipping] + orderTotal[:discount]

        lineItems = Array.new

        order_items = convert_to_array(order[:items][:item])

        order_items.each do |item|
          lineItems.push(item_m_to_w(item))
        end

        adjustments = Array.new
        adjustments.push({
          :name => 'Tax',
          :tax => orderTotal[:tax]
        })
        adjustments.push({
          :name => 'Shipping',
          :shipping => orderTotal[:shipping]
        })
        adjustments.push({
          :name => 'Discount',
          :discount => orderTotal[:discount]
        })

        placed_date = Time.parse(order[:created_at])
        upated_date = Time.parse(order[:updated_at])

        wombat_order = {
          :id => order[:increment_id],
          :magento_order_id => order[:order_id],
          :status => order[:status],
          :email => order[:customer_email],
          :currency => order[:order_currency_code],
          :placed_on => placed_date.utc.iso8601,
          :updated_at => upated_date.utc.iso8601,
          :totals => orderTotal,
          :payments => payments,
          :line_items => lineItems,
          :adjustments => adjustments,
          :billing_address => address_m_to_w(order[:billing_address]),
          :shipping_address => address_m_to_w(order[:shipping_address]),
          :shipping_method => order[:shipping_method]
        }

        if @soapClient.config[:connection_name]
          wombat_order[:channel] = @soapClient.config[:connection_name]
          wombat_order[:source] = @soapClient.config[:connection_name]
          wombat_order[:id] = sprintf("%s_%s", @soapClient.config[:connection_name], wombat_order[:id])
        end

        wombat_orders.push(wombat_order)
      end

      wombat_orders
    end
    
    def get_shipment_objects(orders)
      wombat_shipments = Array.new
      
      orders.each do | order |
        shipment = {
          :id => order[:id],
          :order_id => order[:id],
          :status => "ready",
          :email => order[:email],
          :shipping_method => order[:shipping_method],
          :totals => order[:totals],
          :items => order[:line_items],
          :shipping_address => order[:shipping_address],
          :billing_address => order[:billing_address]
        }
        
        wombat_shipments.push(shipment)
      end
      
      return wombat_shipments
    end

    def cancel_order(payload)
      payload[:order][:id] = remove_connection_name(payload[:order][:id])

      order_response = @soapClient.call :sales_order_cancel, { :order_increment_id => payload[:order][:id] }

      order_response.body[:sales_order_cancel_response][:result]
    end

    def add_shipment(payload)
      payload[:shipment][:order_id] = remove_connection_name(payload[:shipment][:order_id])

      order_response = @soapClient.call :sales_order_info, { :order_increment_id => payload[:shipment][:order_id] }

      order = order_response.body[:sales_order_info_response][:result]

      items_to_send = Array.new

      order_items = convert_to_array(order[:items][:item])

      order_items.each do |item|

        shipment_items = convert_to_array(payload[:shipment][:items])

        shipment_items.each do |shipped_item|
          if shipped_item[:product_id] == item[:sku]
            item_to_send = {
                :order_item_id => item[:item_id],
                :qty => shipped_item[:quantity].to_f
            }
            items_to_send.push(item_to_send)
            break
          end
        end
      end

      shipment_increment_id = @soapClient.call :sales_order_shipment_create, {
                            :order_increment_id => payload[:shipment][:order_id],
                            :items_qty => items_to_send,
                            :email => 1
                          }

      shipment_increment_id = shipment_increment_id.body[:sales_order_shipment_create_response][:shipment_increment_id]

      carrier_code = false
      shipping_method = payload[:shipment][:shipping_method].downcase
      if shipping_method.include? 'dhl'
        carrier_code = 'dhlint'
      elsif shipping_method.include? 'ups' or shipping_method.include? 'united parcel service'
        carrier_code = 'ups'
      elsif shipping_method.include? 'usps' or shipping_method.include? 'united states postal service'
        carrier_code = 'usps'
      elsif shipping_method.include? 'fedex' or shipping_method.include? 'federal express'
        carrier_code = 'fedex'
      end
        if carrier_code
          @soapClient.call :sales_order_shipment_add_track, {
              :shipment_increment_id => shipment_increment_id,
              :carrier => carrier_code,
              :title => payload[:shipment][:shipping_method],
              :track_number => payload[:shipment][:tracking]
          }
      end

      if @soapClient.config[:connection_name]
        shipment_increment_id = sprintf("%s_%s", @soapClient.config[:connection_name], shipment_increment_id)
      end

      shipment_increment_id
    end

    private

    def item_m_to_w(item)
      lineItem = {
          :product_id => item[:sku],
          :name => item[:name],
          :quantity => item[:qty_ordered].to_f,
          :price => item[:price].to_f,
          :product_type => item[:product_type]
      }

      lineItem
    end

    def address_m_to_w(address)
      addressObject = {
          :firstname => address[:firstname],
          :lastname => address[:lastname],
          :address1 => address[:street],
          :zipcode => address[:postcode],
          :city => address[:city],
          :state => address[:region],
          :country => address[:country_id],
          :phone => address[:telephone],
      }

      addressObject
    end

    def remove_connection_name(string)
      if (@soapClient.config[:connection_name]) && (string.include? "#{@soapClient.config[:connection_name]}_")
        return string["#{@soapClient.config[:connection_name]}_".length, string.length]
      end

      string
    end
  end
end
