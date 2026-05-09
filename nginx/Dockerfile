FROM nginx:alpine

# Remove default config
RUN rm /etc/nginx/conf.d/default.conf

# Copy our main config
COPY nginx.conf /etc/nginx/nginx.conf

# conf.d/ will be mounted as a volume at runtime
# so per-env configs appear without rebuilding the image

EXPOSE 80
