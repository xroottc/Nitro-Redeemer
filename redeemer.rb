require 'httparty'
require 'json'
require 'thread'
require 'securerandom'
require 'time'
require 'base64'
require 'colorize'

Thread::abort_on_exception = true
$mutex = Mutex.new
$activated_accounts = 0

class Console
  def self.time
    Time.now.utc.strftime("%H:%M:%S")
  end

  def self.clear
    system(Gem.win_platform? ? "cls" : "clear")
  end

  def self.sprint(content, status = true)
    $mutex.synchronize do
      puts "[#{time.blue}] #{status ? content.green : content.red}"
    end
  end

  def self.update_title
    start_time = Time.now
    loop do
      $mutex.synchronize do
        elapsed = Time.now - start_time
        system("title Naito │ Activated Accounts: #{$activated_accounts} │ Elapsed: #{elapsed.round(2)}s")
      end
      sleep 1
    end
  end
end

class Others
  def self.get_client_data
    JSON.parse(File.read("config.json"))["build_num"]
  end

  def self.remove_content(filename, delete_line)
    $mutex.synchronize do
      lines = File.readlines(filename)
      File.write(filename, lines.reject { |line| line.include?(delete_line) }.join)
    end
  end
end

class Redeemer
  include HTTParty
  base_uri 'https://discord.com/api/v9'

  def initialize(vcc, token, link, build_num, proxy = nil)
    @card_number, @expiry, @ccv = vcc.split(":")
    @link = link.include?("promos.discord.gg/") ? "https://discord.com/billing/promotions/#{link.split('promos.discord.gg/')[1]}" : link
    @token = token.include?(":") ? token.split(":")[2] : token
    @full_token = token if token.include?(":")
    @build_num = build_num
    @proxy = proxy
    @client = HTTParty
    @stripe_client = HTTParty
    default_options.update(http_proxyaddr: proxy["http://"].split(":")[0], http_proxyport: proxy["http://"].split(":")[1]) if proxy
  end

  def tasks
    return unless session
    return unless stripe
    return unless stripe_tokens
    return unless setup_intents
    return unless validate_billing
    return unless stripe_confirm
    return unless add_payment

    redeem_result = redeem
    if redeem_result.nil?
      Console.sprint("Could not redeem nitro, error: #{@error}", false)
      case @error
      when /This payment method cannot be used/
        Others.remove_content("vccs.txt", @card_number)
      when /Already purchased/
        Others.remove_content("tokens.txt", @token)
        $mutex.synchronize do
          File.open("Success.txt", "a") { |f| f.puts(@full_token || @token) }
        end
      when /This gift has been redeemed already/
        Others.remove_content("promolinks.txt", @link)
      end
    elsif redeem_result == "auth"
      return redeem_result
    else
      Console.sprint("Redeemed Nitro -> #{@token}", true)
      Others.remove_content("tokens.txt", @token)
      Others.remove_content("promolinks.txt", @link.split("/promotions/")[1])
      $mutex.synchronize do
        File.open("Success.txt", "a") { |f| f.puts(@full_token || @token) }
        $activated_accounts += 1
      end
    end
  end

  private

  def session
    headers = {
      "Accept" => "*/*",
      "Accept-Language" => "en-US,en;q=0.9",
      "Connection" => "keep-alive",
      "Sec-Fetch-Dest" => "document",
      "Sec-Fetch-Mode" => "navigate",
      "Sec-Fetch-Site" => "none",
      "Sec-Fetch-User" => "?1",
      "Upgrade-Insecure-Requests" => "1",
      "User-Agent" => "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/104.0.5112.39 Safari/537.36",
      "sec-ch-ua" => '".Not/A)Brand";v="99", "Google Chrome";v="103", "Chromium";v="103"',
      "sec-ch-ua-mobile" => "?0",
      "sec-ch-ua-platform" => '"Windows"'
    }
    response = @client.get(@link, headers: headers)
    return false unless [200, 201, 204].include?(response.code)

    @stripe_key = response.body[/STRIPE_KEY: '([^']+)'/, 1]
    @dcfduid = response.headers["set-cookie"][/__dcfduid=([^;]+)/, 1]
    @sdcfduid = response.headers["set-cookie"][/__sdcfduid=([^;]+)/, 1]

    cookies = { "__dcfduid" => @dcfduid, "__sdcfduid" => @sdcfduid, "locale" => "en-US" }
    super_properties = Base64.encode64({
      os: "Windows",
      browser: "Chrome",
      device: "",
      system_locale: "en-US",
      browser_user_agent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/104.0.5112.39 Safari/537.36",
      browser_version: "104.0.5112.39",
      os_version: "10",
      referrer: "",
      referring_domain: "",
      referrer_current: "",
      referring_domain_current: "",
      release_channel: "stable",
      client_build_number: @build_num,
      client_event_source: nil
    }.to_json(separators: [",", ":"])).gsub("\n", "")

    headers.merge!(
      "X-Context-Properties" => "eyJsb2NhdGlvbiI6IlJlZ2lzdGVyIn0=",
      "X-Debug-Options" => "bugReporterEnabled",
      "X-Discord-Locale" => "en-US",
      "X-Super-Properties" => super_properties,
      "Host" => "discord.com",
      "Referer" => @link
    )

    fingerprint_response = @client.get("https://discord.com/api/v9/experiments", headers: headers)
    return false unless [200, 201, 204].include?(fingerprint_response.code)

    @fingerprint = fingerprint_response.parsed_response["fingerprint"]
    headers.merge!("X-Fingerprint" => @fingerprint, "Authorization" => @token, "Origin" => "https://discord.com")
    true
  end

  def stripe
    headers = {
      "accept" => "application/json",
      "accept-language" => "en-CA,en;q=0.9",
      "content-type" => "application/x-www-form-urlencoded",
      "dnt" => "1",
      "origin" => "https://m.stripe.network",
      "referer" => "https://m.stripe.network/",
      "sec-ch-ua" => '".Not/A)Brand";v="99", "Google Chrome";v="103", "Chromium";v="103"',
      "sec-ch-ua-mobile" => "?0",
      "sec-ch-ua-platform" => '"Windows"',
      "sec-fetch-dest" => "empty",
      "sec-fetch-mode" => "cors",
      "sec-fetch-site" => "cross-site",
      "user-agent" => "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/104.0.5112.39 Safari/537.36"
    }

    response = @stripe_client.post("https://m.stripe.com/6", body: "JTdCJTIydjIlMjIlM0EyJTJDJTIyaWQlMjIlM0ElMjIwYWQ5NTYwYzZkYjIxZDRhZTU3ZGM5NmQ0ZThlZGY3OCUyMiUyQyUyMnQlMjIlM0EyNC45JTJDJTIydGFnJTIyJTNBJTIyNC41LjQyJTIyJTJDJTIyc3JjJTIyJTNBJTIyanMlMjIlMkMlMjJhJTIyJTNBJTdCJTIyYSUyMiUzQSU3QiUyMnYlMjIlM0ElMjJmYWxzZSUyMiUyQyUyMnQlMjIlM0EwLjIlN0QlMkMlMjJiJTIyJTNBJTdCJTIydiUyMiUzQSUyMnRydWUlMjIlMkMlMjJ0JTIyJTNBMCU3RCUyQyUyMmMlMjIlM0ElN0IlMjJ2JTIyJTNBJTIyZW4tQ0ElMjIlMkMlMjJ0JTIyJTNBMCU3RCUyQyUyMmQlMjIlM0ElN0IlMjJ2JTIyJTNBJTIyV2luMzIlMjIlMkMlMjJ0JTIyJTNBMCU3RCUyQyUyMmUlMjIlM0ElN0IlMjJ2JTIyJTNBJTIyUERGJTIwVmlld2VyJTJDaW50ZXJuYWwtcGRmLXZpZXdlciUyQ2FwcGxpY2F0aW9uJTJGcGRmJTJDcGRmJTJCJTJCdGV4dCUyRnBkZiUyQ3BkZiUyQyUyMENocm9tZSUyMFBERiUyMFZpZXdlciUyQ2ludGVybmFsLXBkZi12aWV3ZXIlMkNhcHBsaWNhdGlvbiUyRnBkZiUyQ3BkZiUyQiUyQnRleHQlMkZwZGYlMkNwZGYlMkMlMjBDaHJvbWl1bSUyMFBERiUyMFZpZXdlciUyQ2ludGVybmFsLXBkZi12aWV3ZXIlMkNhcHBsaWNhdGlvbiUyRnBkZiUyQ3BkZiUyQiUyQnRleHQlMkZwZGYlMkNwZGYlMkMlMjBNaWNyb3NvZnQlMjBFZGdlJTIwUERGJTIwVmlld2VyJTJDaW50ZXJuYWwtcGRmLXZpZXdlciUyQ2FwcGxpY2F0aW9uJTJGcGRmJTJDcGRmJTJCJTJCdGV4dCUyRnBkZiUyQ3BkZiUyQyUyMFdlYktpdCUyMGJ1aWx0LWluJTIwUERGJTJDaW50ZXJuYWwtcGRmLXZpZXdlciUyQ2FwcGxpY2F0aW9uJTJGcGRmJTJDcGRmJTJCJTJCdGV4dCUyRnBkZiUyQ3BkZiUyMiUyQyUyMnQlMjIlM0EwLjElN0QlMkMlMjJmJTIyJTNBJTdCJTIydiUyMiUzQSUyMjE5MjB3XzEwNDBoXzI0ZF8xciUyMiUyQyUyMnQlMjIlM0EwJTdEJTJDJTIyZyUyMiUzQSU3QiUyMnYlMjIlM0ElMjItNCUyMiUyQyUyMnQlMjIlM0EwJTdEJTJDJTIyaCUyMiUzQSU3QiUyMnYlMjIlM0ElMjJmYWxzZSUyMiUyQyUyMnQlMjIlM0EwJTdEJTJDJTIyaSUyMiUzQSU3QiUyMnYlMjIlM0ElMjJzZXNzaW9uU3RvcmFnZS1kaXNhYmxlZCUyQyUyMGxvY2FsU3RvcmFnZS1kaXNhYmxlZCUyMiUyQyUyMnQlMjIlM0EwLjElN0QlMkMlMjJqJTIyJTNBJTdCJTIydiUyMiUzQSUyMjAxMDAxMDAxMDExMTExMTExMDAxMTExMDExMTExMTExMDExMTAwMTAxMTAxMTExMTAxMTExMTElMjIlMkMlMjJ0JTIyJTNBOS4yJTJDJTIyYXQlMjIlM0EwLjIlN0QlMkMlMjJrJTIyJTNBJTdCJTIydiUyMiUzQSUyMiUyMiUyQyUyMnQlMjIlM0EwJTdEJTJDJTIybCUyMiUzQSU3QiUyMnYlMjIlM0ElMjJNb3ppbGxhJTJGNS4wJTIwKFdpbmRvd3MlMjBOVCUyMDEwLjAlM0IlMjBXT1c2NCklMjBBcHBsZVdlYktpdCUyRjUzNy4zNiUyMChLSFRNTCUyQyUyMGxpa2UlMjBHZWNrbyklMjBDaHJvbWUlMkYxMDMuMC4wLjAlMjBTYWZhcmklMkY1MzcuMzYlMjIlMkMlMjJ0JTIyJTNBMCU3RCUyQyUyMm0lMjIlM0ElN0IlMjJ2JTIyJTNBJTIyJTIyJTJDJTIydCUyMiUzQTAlN0QlMkMlMjJuJTIyJTNBJTdCJTIydiUyMiUzQSUyMmZhbHNlJTIyJTJDJTIydCUyMiUzQTIxLjUlMkMlMjJhdCUyMiUzQTAuMiU3RCUyQyUyMm8lMjIlM0ElN0IlMjJ2JTIyJTNBJTIyMTZlNzljMzY0YjkwNDM0NGU1ODFmNjlhMTI4ZTNkYTglMjIlMkMlMjJ0JTIyJTNBNi4xJTdEJTdEJTJDJTIyYiUyMiUzQSU3QiUyMmElMjIlM0ElMjJodHRwcyUzQSUyRiUyRkdTN2hxbmtaQlJwUF83V245LUNHRmh6cTRrcjJYM0pDNEEzazZCREJ2cEUuZzJ1OS1ocVp2R0lxWUpjUGxQZndKQWYtdjNSZ3lLX3gxTnBwekFsQTEyTSUyRkJRZE55enBMVTRuTTZZS3p6bmFQMVhDRDFXMERKMXozVHBudHoyWnBJcXMlMkYwc0x5MVBQSUkyaG0zT0RIaUxadUtjNlJkeWNMRTFWcm1yeW50c1hYdDdvJTJGb1dwRTZfai1tS0tFS25CWEVpbVVZMDJRTVlfTklJanRPblZHbHUwblFmVSUyMiUyQyUyMmIlMjIlM0ElMjJodHRwcyUzQSUyRiUyRkdTN2hxbmtaQlJwUF83V245LUNHRmh6cTRrcjJYM0pDNEEzazZCREJ2cEUuZzJ1OS1ocVp2R0lxWUpjUGxQZndKQWYtdjNSZ3lLX3gxTnBwekFsQTEyTSUyRkJRZE55enBMVTRuTTZZS3p6bmFQMVhDRDFXMERKMXozVHBudHoyWnBJcXMlMkYwc0x5MVBQSUkyaG0zT0RIaUxadUtjNlJkeWNMRTFWcm1yeW50c1hYdDdvJTJGb1dwRTZfai1tS0tFS25CWEVpbVVZMDJRTVlfTklJanRPblZHbHUwblFmVSUyMiUyQyUyMmMlMjIlM0ElMjJfSWwxX2c2VDlzcjVXcS10eUhkZUwxZWVFdHo3TzdJRE8xZ3JDLU5aY1VrJTIyJTJDJTIyZCUyMiUzQSUyMjBiOTYwMGE5LTkyNjctNGViNi05NGNhLTM1MzNhMDE4NGExMTQxMDc3NiUyMiUyQyUyMmUlMjIlM0ElMjJmOGFkN2Y2Ny1lMWFmLTQxZTctYjlmMy1kNzRjZGRlMGI1NGQzZThiODAlMjIlMkMlMjJmJTIyJTNBZmFsc2UlMkMlMjJnJTIyJTNBdHJ1ZSUyQyUyMmglMJIlM0F0cnVlJTJDJTIyaSUyMiUzQSU1QiUyMmxvY2F0aW9uJTIyJTVEJTJDJTIyaiUyMiUzQSU1QiU1RCUyQyUyMm4lMjIlM0EyNjcuNSUyQyUyMnUlMjIlM0ElMjJkaXNjb3JkLmNvbSUyMiUyQyUyMnYlMjIlM0ElMjJkaXNjb3JkLmNvbSUyMiU3RCUyQyUyMmglMjIlM0ElMjI5NjI5ZjFjZWM1NGY1YjhmM2IxYSUyMiU3RA==", headers: headers)

    return false unless [200, 201, 204].include?(response.code)

    @muid = response.parsed_response["muid"]
    @guid = response.parsed_response["guid"]
    @sid = response.parsed_response["sid"]
    cookies.update("__stripe_mid" => @muid, "__stripe_sid" => @sid)
    true
  end

  def stripe_tokens
    headers = { "Authorization" => "Bearer #{@stripe_key}" }
    data = "card[number]=#{@card_number}&card[cvc]=#{@ccv}&card[exp_month]=#{@expiry[0..1]}&card[exp_year]=#{@expiry[-2..-1]}&guid=#{@guid}&muid=#{@muid}&sid=#{@sid}&payment_user_agent=stripe.js%2Ff0346bf10%3B+stripe-js-v3%2Ff0346bf10&time_on_page=#{rand(60000..120000)}&key=#{@stripe_key}&pasted_fields=number%2Cexp%2Ccvc"
    response = @stripe_client.post("https://api.stripe.com/v1/tokens", body: data, headers: headers)
    @confirm_token = response.parsed_response["id"] if response.code == 200
    response.code == 200
  end

  def setup_intents
    response = @client.post("/users/@me/billing/stripe/setup-intents")
    @client_secret = response.parsed_response["client_secret"] if response.code == 200
    response.code == 200
  end

  def validate_billing(name: "John Wick", line_1: "27 Oakland Pl", line_2: "", city: "Brooklyn", state: "NY", postal_code: "11226", country: "US", email: "")
    @name, @line_1, @line_2, @city, @state, @postal_code, @country, @email = name, line_1, line_2, city, state, postal_code, country, email
    response = @client.post("/users/@me/billing/payment-sources/validate-billing-address", body: { billing_address: { name: name, line_1: line_1, line_2: line_2, city: city, state: state, postal_code: postal_code, country: country, email: email } }.to_json)
    @billing_token = response.parsed_response["token"] if response.code == 200
    response.code == 200
  end

  def parse_data(content)
    content.gsub(" ", "+")
  end

  def stripe_confirm
    @depracted_client_secret = @client_secret.split("_secret_")[0]
    data = "payment_method_data[type]=card&payment_method_data[card][token]=#{@confirm_token}&payment_method_data[billing_details][address][line1]=#{parse_data(@line_1)}&payment_method_data[billing_details][address][line2]=#{parse_data(@line_2) if @line_2 != ''}&payment_method_data[billing_details][address][city]=#{@city}&payment_method_data[billing_details][address][state]=#{@state}&payment_method_data[billing_details][address][postal_code]=#{@postal_code}&payment_method_data[billing_details][address][country]=#{@country}&payment_method_data[billing_details][name]=#{parse_data(@name)}&payment_method_data[guid]=#{@guid}&payment_method_data[muid]=#{@muid}&payment_method_data[sid]=#{@sid}&payment_method_data[payment_user_agent]=stripe.js%2Ff0346bf10%3B+stripe-js-v3%2Ff0346bf10&payment_method_data[time_on_page]=#{rand(210000..450000)}&expected_payment_method_type=card&use_stripe_sdk=true&key=#{@stripe_key}&client_secret=#{@client_secret}"
    response = @stripe_client.post("https://api.stripe.com/v1/setup_intents/#{@depracted_client_secret}/confirm", body: data)
    @payment_id = response.parsed_response["payment_method"] if response.code == 200
    response.code == 200
  end

  def add_payment
    payload = {
      payment_gateway: 1,
      token: @payment_id,
      billing_address: { name: @name, line_1: @line_1, line_2: @line_2, city: @city, state: @state, postal_code: @postal_code, country: @country, email: @email },
      billing_address_token: @billing_token
    }
    response = @client.post("/users/@me/billing/payment-sources", body: payload.to_json)
    if response.code == 200
      @payment_source_id = response.parsed_response["id"]
      true
    else
      @error = response.parsed_response["errors"]["_errors"][0]["message"]
      false
    end
  end

  def redeem
    response = @client.post("/entitlements/gift-codes/#{@link.split('https://discord.com/billing/promotions/')[1]}/redeem", body: { channel_id: nil, payment_source_id: @payment_source_id }.to_json)
    return true if response.code == 200
    return "auth" if response.parsed_response["message"] == "Authentication required"
    @error = response.parsed_response["message"]
    false
  end
end

class Authentication < Redeemer
  def initialize(vcc, token, link, build_num = Others.get_client_data, proxy = nil)
    super(vcc, token, link, build_num, proxy)
    begin
      if tasks == "auth"
        return unless discord_payment_intents
        sleep 0.2
        return unless stripe_payment_intents
        sleep 0.2
        return unless stripe_payment_intents_2
        sleep 0.2
        return unless stripe_fingerprint
        sleep 0.2
        return unless authenticate
        sleep 0.2
        return unless billing
        sleep 0.2

        redeem_result = redeem
        if redeem_result.nil?
          Console.sprint("Could not redeem nitro, error: #{@error}", false)
          Others.remove_content("vccs.txt", @card_number) if @error.include?("This payment method cannot be used")
        elsif redeem_result == "auth"
          Console.sprint("Could not authenticate vcc", false)
        else
          Console.sprint("Redeemed Nitro -> #{@token}", true)
          Others.remove_content("tokens.txt", @token)
          Others.remove_content("promolinks.txt", @link.split("/promotions/")[1])
          $mutex.synchronize do
            File.open("Success.txt", "a") { |f| f.puts(@full_token || @token) }
            $activated_accounts += 1
          end
        end
      end
    rescue => e
      Console.sprint("An error occurred: #{e}", false)
    end
  end

  private

  def discord_payment_intents
    response = @client.get("/users/@me/billing/stripe/payment-intents/payments/#{@stripe_payment_id}")
    if response.code == 200
      @stripe_payment_intent_client_secret = response.parsed_response["stripe_payment_intent_client_secret"]
      @depracted_stripe_payment_intent_client_secret = @stripe_payment_intent_client_secret.split("_secret_")[0]
      @stripe_payment_intent_payment_method_id = response.parsed_response["stripe_payment_intent_payment_method_id"]
      true
    else
      false
    end
  end

  def stripe_payment_intents
    response = @stripe_client.get("https://api.stripe.com/v1/payment_intents/#{@depracted_stripe_payment_intent_client_secret}?key=#{@stripe_key}&is_stripe_sdk=false&client_secret=#{@stripe_payment_intent_client_secret}")
    response.code == 200
  end

  def stripe_payment_intents_2
    data = { expected_payment_method_type: "card", use_stripe_sdk: "true", key: @stripe_key, client_secret: @stripe_payment_intent_client_secret }
    response = @stripe_client.post("https://api.stripe.com/v1/payment_intents/#{@depracted_stripe_payment_intent_client_secret}/confirm", body: data)
    if response.code == 200
      @server_transaction_id = response.parsed_response["next_action"]["use_stripe_sdk"]["server_transaction_id"]
      @three_d_secure_2_source = response.parsed_response["next_action"]["use_stripe_sdk"]["three_d_secure_2_source"]
      @merchant = response.parsed_response["next_action"]["use_stripe_sdk"]["merchant"]
      @three_ds_method_url = response.parsed_response["next_action"]["use_stripe_sdk"]["three_ds_method_url"]
      true
    else
      false
    end
  end

  def stripe_fingerprint
    three_ds_method_notification_url = "https://hooks.stripe.com/3d_secure_2/fingerprint/#{@merchant}/#{@three_d_secure_2_source}"
    data = { threeDSMethodData: Base64.encode64({ threeDSServerTransID: @server_transaction_id }.to_json(separators: [",", ":"])).gsub("\n", "") }
    response = @stripe_client.post(three_ds_method_notification_url, body: data)
    response.code == 200
  end

  def authenticate
    data = "source=#{@three_d_secure_2_source}&browser=%7B%22fingerprintAttempted%22%3Atrue%2C%22fingerprintData%22%3A%22#{Base64.encode64({ threeDSServerTransID: @server_transaction_id }.to_json(separators: [",", ":"])).gsub("\n", "")}%22%2C%22challengeWindowSize%22%3Anull%2C%22threeDSCompInd%22%3A%22Y%22%2C%22browserJavaEnabled%22%3Afalse%2C%22browserJavascriptEnabled%22%3Atrue%2C%22browserLanguage%22%3A%22en-US%22%2C%22browserColorDepth%22%3A%2224%22%2C%22browserScreenHeight%22%3A%221080%22%2C%22browserScreenWidth%22%3A%221920%22%2C%22browserTZ%22%3A%22240%22%2C%22browserUserAgent%22%3A%22Mozilla%2F5.0+(Windows+NT+10.0%3B+Win64%3B+x64)+AppleWebKit%2F537.36+(KHTML%2C+like+Gecko)+Chrome%2F104.0.5112.39+Safari%2F537.36%22%7D&one_click_authn_device_support[hosted]=false&one_click_authn_device_support[same_origin_frame]=false&one_click_authn_device_support[spc_eligible]=true&one_click_authn_device_support[webauthn_eligible]=true&one_click_authn_device_support[publickey_credentials_get_allowed]=true&key=#{@stripe_key}"
    response = @stripe_client.post("https://api.stripe.com/v1/3ds2/authenticate", body: data)
    response.code == 200
  end

  def billing
    response = @client.get("/users/@me/billing/payments/#{@stripe_payment_id}")
    response.code == 200
  end
end

if __FILE__ == $PROGRAM_NAME
  Console.clear
  system("title Naito Redeemer | naito.sell.app")
  system(Gem.win_platform? ? "cls" : "clear")
  puts <<~BANNER.blue
    ____           __                             
   / __ \\___  ____/ /__  ___  ____ ___  ___  _____
  / /_/ / _ \\/ __  / _ \\/ _ \\/ __ `__ \\/ _ \\/ ___/
 / _, _/  __/ /_/ /  __/  __/ / / / / /  __/ /    
/_/ |_|\\___/\\__,_/\\___/\\___/_/ /_/ /_/\\___/_/     
                                                                             
          -> https://ogu.gg/heracles                                   
          -> Nitro Redeemer
  BANNER

  config = JSON.parse(File.read("config.json"))
  proxies = File.readlines("proxies.txt").map(&:chomp).cycle
  vccs = File.readlines("vccs.txt").map(&:chomp)
  tokens = File.readlines("tokens.txt").map(&:chomp)
  promolinks = File.readlines("promolinks.txt").map(&:chomp)
  use_on_vcc = config["use_on_vcc"]
  thread_count = config["threads"]
  build_num = Others.get_client_data

  duplicate_vccs = vccs.flat_map { |vcc| Array.new(use_on_vcc, vcc) }

  until vccs.empty? || tokens.empty? || promolinks.empty?
    begin
      threads = []
      thread_count.times do
        break if tokens.empty? || promolinks.empty? || duplicate_vccs.empty?
        proxy = begin
                  { "http://" => "http://#{proxies.next}", "https://" => "http://#{proxies.next}" }
                rescue StopIteration
                  nil
                end
        token = tokens.shift
        vcc = duplicate_vccs.shift
        link = promolinks.shift

        threads << Thread.new { Authentication.new(vcc, token, link, build_num, proxy) }
        Others.remove_content("vccs.txt", vcc) unless duplicate_vccs.include?(vcc)
      end
      threads.each(&:join)
    rescue IndexError
      break
    rescue => e
      Console.sprint("Error: #{e}", false)
    end
  end
  Console.sprint("Materials ran out, threads might of not finished yet", false)
end
