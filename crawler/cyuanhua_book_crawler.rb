require 'crawler_rocks'
require 'json'
require 'iconv'
require 'isbn'
require 'pry'
require 'book_toolkit'

require 'thread'
require 'thwait'

class CyuanhuaBookCrawler
  include CrawlerRocks::DSL

  def initialize update_progress: nil, after_each: nil
    @update_progress_proc = update_progress
    @after_each_proc = after_each

    @search_url = "http://www.opentech.com.tw/search/result.asp"
    @post_action = "http://www.opentech.com.tw/search_top.asp"
    @index_url = "http://www.opentech.com.tw/index2N.asp"
    @ic = Iconv.new("utf-8//translit//IGNORE","big5")
  end

  def books
    @book_urls = []
    @books = []
    @threads = []

    r = post_search
    doc = Nokogiri::HTML(@ic.iconv r)

    table_selector = 'table[border="0"][cellpadding="0"][cellspacing="0"][width="100%"]'
    tables = doc.css(table_selector)[3]

    book_count = tables.css('td.fw font')[1].text.to_i
    page_count = tables.css('td.fw font')[3].text.to_i

    # (1..5).each do |i|
    done_page_count = 0
    (1..page_count).each do |i|
      sleep(1) until (
        @threads.delete_if { |t| !t.status };  # remove dead (ended) threads
        @threads.count < (ENV['MAX_THREADS'] || 25)
      )
      @threads << Thread.new do
        r = RestClient.get @search_url + "?page=#{i}&flag=true", cookies: @cookies
        doc = Nokogiri::HTML(@ic.iconv r)

        @book_urls.concat doc.css('a').map{|a| a[:href]}.select{|href| href.match(/\.\.\/search\/bookinfo\.asp\?isbn=/)}.map{|href| URI.join(@search_url, href).to_s }
        done_page_count += 1
        print "#{done_page_count} / #{page_count}\n"
      end
    end

    ThreadsWait.all_waits(*@threads)

    @book_urls.uniq!

    @threads = []

    book_count = @book_urls.count
    done_book_count = 0

    @book_urls.each_with_index do |url, index|
      sleep(1) until (
        @threads.delete_if { |t| !t.status };  # remove dead (ended) threads
        @threads.count < (ENV['MAX_THREADS'] || 5)
      )
      @threads << Thread.new do
        begin
          r = RestClient.get url, cookies: @cookies
        rescue Exception => e
          print "error! #{url}\n"
          post_search()
          sleep 3
          # r = RestClient.get url, cookies: @cookies
          redo
        end
        doc = Nokogiri::HTML(@ic.iconv(r))
        # isbn = CGI.parse(URI.parse(url).query)["isbn"].first

        external_image_url = doc.css('img').map{|img| img[:src]}.find{|src| src && src.include?('cbook') }
        external_image_url = URI.join("http://www.opentech.com.tw", external_image_url).to_s if external_image_url

        name = doc.css('.fw1').text.strip.gsub(/^[\ \s]+/, '')

        author = nil; original_price = nil; publisher = nil; isbn = nil; isbn_10 = nil;
        internal_code = nil;
        table = doc.css('table[width="600"] td.fw')[0]
        table.css('tr').each do |row|
          str = row.text.strip
          str.match(/作\(譯\)者：/) {|m| author = str.split('：').last.strip}
          str.match(/定　價：NT\$([\d,]+)/) {|m| original_price = m[1].gsub(/[^\d]/, '').to_i }
          str.match(/出版商：(.+?)\s+?/) {|m| publisher = m[1] }
          str.match(/ISBN.+?\：(.+?)\s+?/) do |m|
            if m[1].length != 13
              isbn_10 = m[1]
              isbn = isbn_10
            else
              isbn = m[1]
            end
          end
          str.match(/書號\：(.+?)\s+?/) {|m| internal_code = m[1] }
        end

        invalid_isbn = nil
        begin
          isbn = BookToolkit.to_isbn13(isbn)
        rescue Exception => e
          invalid_isbn = isbn
          isbn = nil
        end

        book = {
          name: name,
          isbn: isbn,
          invalid_isbn: isbn,
          isbn_10: isbn_10,
          author: author,
          external_image_url: external_image_url,
          original_price: original_price,
          publisher: publisher,
          internal_code: internal_code,
          url: url,
          known_supplier: 'cyuanhua'
        }

        @after_each_proc.call(book: book) if @after_each_proc

        @books << book
        done_book_count += 1
        # print "#{done_book_count} / #{book_count}\n"
      end # end Thread
    end # end each book_urls
    ThreadsWait.all_waits(*@threads)
    @books
  end

  def post_search
    RestClient.post(@post_action, {
      :lpszSearchFor => ' ',
      'SEARCHBOOK' => 'title',
      'go-button_pressed.x' => 38,
      'go-button_pressed.y' => 9,
      'go-button_pressed' => 'Go',
    }) do |response, request, result, &block|
      if [301, 302, 307].include? response.code
        @cookies = response.cookies
        response.follow_redirection(request, result, &block)
      else
        response.return!(request, result, &block)
      end
    end
  end

end

# cc = CyuanhuaBookCrawler.new
# File.write('cyuanhua_books.json', JSON.pretty_generate(cc.books))
