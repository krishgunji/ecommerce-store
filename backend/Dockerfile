# Use official Node.js LTS (Alpine for smaller size)
FROM node:18-alpine

# Set working directory
WORKDIR /app

# Copy package files and install dependencies first for optimized Docker cache
COPY package*.json ./
RUN npm install --production

# Copy rest of your app source code
COPY . .

# Expose the backend port (default 5000)
EXPOSE 5000

# Run the backend application
CMD ["node", "app.js"]
