class AdminController < ApplicationController
  # Authentication stuff
  before_filter :redirect_to_ssl
  before_filter :check_authentication, :except => [:login]

  def login
    unless params[:username] && params[:password]
      render :action => "login" and return
    end

    if params[:username] == $STORE_PREFS['admin_username'] &&
       params[:password] == $STORE_PREFS['admin_password']
      session[:logged_in] = true
      if session[:intended_url] != nil
        redirect_to session[:intended_url]
      else
        redirect_to :action => 'index'
      end
    else
      flash[:notice] = "Go home kid. This ain't for you."
      render :action => "login"
    end
  end

  def logout
    session[:logged_in] = nil
    redirect_to home_url
  end

  # Dashboard page
  def index
    if Product.count == 0
      flash[:notice] = "This store doesn't have any products! Add some!"
      redirect_to :action => 'products' and return
    end

    revenue_summary()
    revenue_initial()
  end
  
  def revenue_initial
    limit = 30
    query_results = Order.connection.select_all(revenue_history_days_sql(limit))

    labels = []
    data = []

    0.upto(limit-1) {
      labels << ''
      data << 0
    }
    
    labels = (29.days.ago.to_date..Date.today).map {|date| date.strftime('%b %d')}

    query_results.each {|x|
      xindex = -x['days_ago'].to_i + limit-1
      next if xindex < 0 || xindex > limit-1
      revenue = x['revenue'].to_f.round
      data[xindex] = revenue
    }

    hash = { }
    hash["labels"] = labels
    hash["data"] = data
    @chart = hash
  end

  def revenue_history_days
    @type = "30 Day"
    
    revenue_initial()
    render :partial =>  "revenue_history"
  end

  # Revenue summary
  private
  def revenue_history_days_sql(days)
    if Order.connection.adapter_name == 'PostgreSQL'
      "select extract(year from orders.order_time) as year,
              extract(month from orders.order_time) as month,
              extract(day from orders.order_time) as day,
              extract(day from age(date_trunc('day', orders.order_time))) as days_ago,
              (sum(line_items.unit_price * quantity)
                - sum(coalesce(regional_prices.amount, coupons.amount, 0))
                - sum(line_items.unit_price * quantity * coalesce(percentage, 0) / 100)) * orders.currency_rate as revenue,
              max(orders.order_time) as last_time

         from orders
              inner join line_items on orders.id = line_items.order_id
              left outer join coupons on coupons.id = orders.coupon_id
              left outer join regional_prices on regional_prices.container_id = coupons.id AND regional_prices.container_type = 'Product' AND regional_prices.currency = orders.currency

        where status = 'C' and lower(payment_type) != 'free' and current_date - #{days-1} <= order_time

        group by year, month, day, days_ago

        order by last_time desc"
    else
      "select extract(year from orders.order_time) as year,
              extract(month from orders.order_time) as month,
              extract(day from orders.order_time) as day,
              datediff(now(), orders.order_time) as days_ago,
              (sum(line_items.unit_price * quantity)
                - sum(coalesce(regional_prices.amount, coupons.amount, 0))
                - sum(line_items.unit_price * quantity * coalesce(percentage, 0) / 100)) * orders.currency_rate as revenue,
              max(orders.order_time) as last_time

         from orders
              inner join line_items on orders.id = line_items.order_id
              left outer join coupons on coupons.id = orders.coupon_id
              left outer join regional_prices on regional_prices.container_id = coupons.id AND regional_prices.container_type = 'Product' AND regional_prices.currency = orders.currency

        where status = 'C' and lower(payment_type) != 'free' and current_date - #{days-1} <= order_time

        group by year, month, day, days_ago

        order by last_time desc"
    end
  end
  
  def revenue_summary
    # NOTE: We have to use SQL because performance is completely unacceptable otherwise
    # helper function
    def last_n_days_sql(days)

      if Order.connection.adapter_name == 'PostgreSQL'
        "select (select count(*)
                   from orders
                  where status = 'C' and total > 0 and current_date - #{days-1} <= order_time) as orders,
                sum(unit_price * quantity) as revenue,
                sum(quantity) as quantity,
                products.code as product_name

           from orders
                inner join line_items on orders.id = line_items.order_id
                left outer join products on products.id = line_items.product_id

          where status = 'C' and total > 0 and current_date - #{days-1} <= order_time
          group by product_name"
      else
        "select (select count(*)
                   from orders
                  where status = 'C' and total > 0 and datediff(current_date(), order_time) <= #{days-1}) as orders,
                sum(unit_price * quantity) as revenue,
                sum(quantity) as quantity,
                products.code as product_name

           from orders
                inner join line_items on orders.id = line_items.order_id
                left outer join products on products.id = line_items.product_id

          where status = 'C' and total > 0 and datediff(current_date(), order_time) <=  #{days-1}
          group by product_name"
        end
    end

    query_results = []
    @num_orders = []
    @revenue = []
    @product_revenue = {}
    @product_quantity = {}
    @product_percentage = {}

    for days in [1, 7, 30, 365]
      query_results << Order.connection.select_all(last_n_days_sql(days))
    end
    @products = query_results[-1].map{|p| p["product_name"]}

    # calculate the numbers to report
    for result in query_results
      orders = 0
      total = 0
      for row in result
        name = row["product_name"]
        name.upcase! if name
        @product_revenue[name] = [] if @product_revenue[name] == nil
        @product_quantity[name] = [] if @product_quantity[name] == nil
        @product_revenue[name] << row["revenue"]
        @product_quantity[name] << row["quantity"]
        orders = row["orders"]
        total = total.to_f + row["revenue"].to_f
      end
      @num_orders << orders
      @revenue << total
    end

    for product in @products
      @product_revenue[product].insert(0, 0) while @product_revenue[product].length < 4
      @product_quantity[product].insert(0, 0) while @product_quantity[product].length < 4
      @product_percentage[product] = []
      for i in 0..3
        if @revenue[i].to_f == 0
          @product_percentage[product] << 0
        else
          @product_percentage[product] << @product_revenue[product][i].to_f / @revenue[i].to_f * 100.0
        end
      end
    end

    def last_n_days_revenue(days)
      if Order.connection.adapter_name == 'PostgreSQL'
        last_n_days_sql = "
          select sum(total) as revenue
            from orders
           where status = 'C' and total > 0 and current_date - #{days-1} <= order_time"
      else
        last_n_days_sql = "
          select sum(total) as revenue
            from orders
           where status = 'C' and total > 0 and datediff(current_date(), order_time) <=  #{days-1}"
      end

      result = Order.connection.select_all(last_n_days_sql)
      return (result != nil && !result.empty? && result[0]["revenue"] != nil) ? result[0]["revenue"] : 0
    end

    @month_estimate = 0
    @year_estimate = 0

    daily_avg = last_n_days_revenue(90).to_f / 90.0

    # Calculate a very simple sales projection.
    # Takes the average daily sales from the last 90 days to extrapolate the sales
    # for the remaining days of the current month and the next 365 days
    today = Date.today
    days_in_current_month = Date.civil(today.year, today.month, -1).day

    if daily_avg != nil
      @month_estimate = daily_avg * days_in_current_month
      @year_estimate = daily_avg * 365
    end
  end

end
