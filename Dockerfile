FROM ruby:3.2.2

RUN apt-get update -qq && \
    apt-get install -y build-essential libpq-dev nodejs vim && \
    curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | apt-key add - && \
    echo "deb https://dl.yarnpkg.com/debian/ stable main" | tee /etc/apt/sources.list.d/yarn.list && \
    apt-get update && apt-get install -y yarn

WORKDIR /app

# 先に Gemfile をコピーして bundle install のキャッシュを有効化
COPY Gemfile Gemfile.lock /app/
RUN bundle install

# 先に package.json, yarn.lock をコピーして yarn install のキャッシュを有効化
COPY package.json yarn.lock /app/
RUN yarn install --check-files --frozen-lockfile

# その後、全てのファイルをコピー
COPY . /app
COPY entrypoint.sh /usr/bin/
RUN chmod +x /usr/bin/entrypoint.sh
ENTRYPOINT ["entrypoint.sh"]
EXPOSE 3000

CMD ["bash", "-c", "yarn vite build && rails server -b 0.0.0.0"]
