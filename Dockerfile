FROM node:22-bookworm

# 1) the read-only xray-terminal CLI the bot runs for every scan
RUN git clone --depth 1 https://github.com/crptAtlas/xray-terminal.git /opt/xray \
 && cd /opt/xray && npm install

# 2) the bot itself
WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev
COPY bot.mjs ./

ENV XRAY_DIR=/opt/xray
ENV DATA_DIR=/data
ENV HOME=/data
CMD ["node", "bot.mjs"]
