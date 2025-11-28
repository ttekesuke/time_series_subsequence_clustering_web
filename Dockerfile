FROM ruby:3.3.0

# 必要なパッケージをインストール
RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
      build-essential libpq-dev nodejs vim curl supercollider && \
    curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | apt-key add - && \
    echo "deb https://dl.yarnpkg.com/debian/ stable main" | tee /etc/apt/sources.list.d/yarn.list && \
    apt-get update && apt-get install -y --no-install-recommends yarn && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Gemfile のキャッシュを活用
COPY Gemfile Gemfile.lock /app/

# ★追加: gemのインストール先を vendor/bundle に設定
# これにより、gemが /app/vendor/bundle にインストールされます
RUN bundle config set --local path 'vendor/bundle'

RUN bundle install

# メモリ節約のため、環境変数を設定
ENV NODE_OPTIONS="--max_old_space_size=384"

# package.json, yarn.lock のキャッシュを活用し、メモリを節約しながら yarn install
COPY package.json yarn.lock /app/
RUN yarn install --network-concurrency 1 --prefer-offline --pure-lockfile --frozen-lockfile

# アプリ全体をコピー
COPY . /app
COPY entrypoint.sh /usr/bin/
RUN chmod +x /usr/bin/entrypoint.sh
ENTRYPOINT ["entrypoint.sh"]
EXPOSE 3000

# vite build をメモリ制限付きで実行
RUN node node_modules/.bin/vite build --no-minify

# scuser ユーザーで起動　sc実行のため必要
RUN useradd -ms /bin/bash scuser

# /app 全体の所有権を scuser に変更
# これにより vendor/bundle や .bundle/config も scuser が読み書きできるようになります
RUN chown -R scuser:scuser /app

USER scuser

CMD ["rails", "server", "-b", "0.0.0.0"]
