FROM node:11-alpine AS build

RUN apk add --no-cache python3 make g++

# Set python3 as default python for node-gyp
ENV PYTHON=python3

WORKDIR /app

COPY package.json package-lock.json ./

RUN npm ci

COPY . .

RUN npm run build

FROM nginx:alpine

COPY --from=build /app/build /usr/share/nginx/html

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
