FROM ruby:3.2.2

# 必要なパッケージをインストール（不要なキャッシュを削除）
RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends build-essential libpq-dev nodejs vim curl python3 python3-pip python3-venv  libpython3-dev && \
    curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | apt-key add - && \
    echo "deb https://dl.yarnpkg.com/debian/ stable main" | tee /etc/apt/sources.list.d/yarn.list && \
    apt-get update && apt-get install -y --no-install-recommends yarn && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# 仮想環境を作って dissonant を安全にインストール
RUN python3 -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
RUN pip install --upgrade pip setuptools
RUN pip install dissonant numpy


# PyCallにPythonパスを明示（pycallはこの環境変数を見る）
ENV PYTHON=/usr/bin/python3

WORKDIR /app

# Gemfile のキャッシュを活用
COPY Gemfile Gemfile.lock /app/
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

CMD [ "rails","server","-b","0.0.0.0" ]
