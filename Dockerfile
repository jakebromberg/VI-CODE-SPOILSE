FROM nginx:alpine

COPY web/offline-bundle/ /usr/share/nginx/html/

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]