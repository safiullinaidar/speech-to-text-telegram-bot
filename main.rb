require 'telegram/bot'
require 'aws-sdk-s3'
require 'dotenv/load'
require 'httparty'
require 'debug'
require 'uri'
require 'net/http'
require 'openssl'
require 'json'

Telegram::Bot::Client.run(ENV['TELEGRAM_TOKEN']) do |bot|
  bot.listen do |message|
    # Get iformation about recordered voice message.
    url = URI("https://api.telegram.org/bot#{ENV['TELEGRAM_TOKEN']}/getFile")
    http = Net::HTTP.new(url.host, url.port)
    http.use_ssl = true

    request = Net::HTTP::Post.new(url)
    request["Accept"] = 'application/json'
    request["Content-Type"] = 'application/json'
    request.body = "{\"file_id\":\"#{message.voice.file_id}\"}"

    response = http.request(request)    
    json_response = JSON.parse(response.body)

    # Download voice message to the temporary folder.
    file_path = json_response["result"]["file_path"]
    file_content_url = "https://api.telegram.org/file/bot#{ENV['TELEGRAM_TOKEN']}/" + "#{file_path}"

    File.open("/tmp/audio.ogg", "wb") do |f| 
      f.write HTTParty.get(file_content_url).body
    end

    # Send downloaded file to Yandex Cloud backet.
    Aws.config.update(region: 'ru-central1', credentials: Aws::Credentials.new(
                                              ENV['AWS_ACCESS_KEY_ID'], ENV['AWS_SECRET_ACCESS_KEY']))
    s3 = Aws::S3::Client.new(endpoint: "https://storage.yandexcloud.net")

    File.open("/tmp/audio.ogg", "r") do |file|
      pp = s3.put_object({ bucket: 'telegramm-bot', key: 'audio.ogg', body: file })
    end

    # Send stored audio file to Yandex Speech Kit for recognition and wait untill it is done.
    options = {
      headers: {"Authorization": "Api-Key #{ENV['API_KEY']}"},
      body: {
         "config": { "specification": { "languageCode" => "ru-RU" } },
         "audio": { "uri": "https://storage.yandexcloud.net/telegramm-bot/audio.ogg" }
      }.to_json
    }
    transaction_response = HTTParty.post('https://transcribe.api.cloud.yandex.net/speech/stt/v2/longRunningRecognize', options).to_h

    option = { headers: { "Authorization" => "Api-Key #{ENV['API_KEY']}" } }
    done = false
    until done
      yandex_answer = HTTParty.get("https://operation.api.cloud.yandex.net/operations/#{transaction_response['id']}", option).to_h
      puts yandex_answer
      done = yandex_answer['done']
    
      sleep 3
    end

    # Parse the response from Yandex Speech Kit and send it back to the bot.
    yandex_array = yandex_answer["response"]["chunks"]
    yandex_text = [] 
   
    yandex_array.each do |elem|
      yandex_text << elem["alternatives"].first["text"]
    end
    
    pp yandex_text.uniq!

    `touch test.txt`
    File.open("test.txt", 'w') { |file| file.write(":#{yandex_text.join(' ')}") }
  end
end
