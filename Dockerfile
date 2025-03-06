FROM ruby:3.2.2

# 必要なパッケージをインストール（不要なキャッシュを削除）
RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends build-essential libpq-dev nodejs vim curl && \
    curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | apt-key add - && \
    echo "deb https://dl.yarnpkg.com/debian/ stable main" | tee /etc/apt/sources.list.d/yarn.list && \
    apt-get update && apt-get install -y --no-install-recommends yarn && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Gemfile のキャッシュを活用
COPY Gemfile Gemfile.lock /app/
RUN bundle install

# package.json, yarn.lock のキャッシュを活用し、メモリを節約しながら yarn install
COPY package.json yarn.lock /app/
RUN NODE_OPTIONS="--max-old-space-size=256" \
    yarn install --network-concurrency 1 --prefer-offline --pure-lockfile --frozen-lockfile

# # 事前ビルド済みの JS ファイルを含める
# COPY public/assets /app/public/assets

# アプリ全体をコピー
COPY . /app
COPY entrypoint.sh /usr/bin/
RUN chmod +x /usr/bin/entrypoint.sh
ENTRYPOINT ["entrypoint.sh"]
EXPOSE 3000

# Vite のビルドはしない（Rails のみ起動）
CMD ["bash", "-c", "rails server -b 0.0.0.0"]
