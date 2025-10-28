# Multi-stage build for Spring Boot application
FROM eclipse-temurin:21-jdk-alpine AS builder

# Set working directory
WORKDIR /app

# Copy Maven wrapper and parent POM (build from root context)
COPY mvnw ./
COPY .mvn ./.mvn
COPY pom.xml ./

# Copy module files
COPY web/pom.xml ./web/
COPY worker/pom.xml ./worker/
COPY web/src ./web/src

# Build the application
RUN chmod +x mvnw && ./mvnw clean package -pl web -am -DskipTests

# Runtime stage
FROM eclipse-temurin:21-jre-alpine

# Install necessary packages and create non-root user
RUN apk add --no-cache curl && \
    addgroup -g 1001 appgroup && \
    adduser -u 1001 -G appgroup -s /bin/sh -D appuser

# Set working directory
WORKDIR /app

# Copy the built jar from builder stage
COPY --from=builder /app/web/target/assets-manager-web-*.jar app.jar

# Change ownership to non-root user
RUN chown -R appuser:appgroup /app

# Switch to non-root user
USER appuser

# Expose the port the app runs on
EXPOSE 8080

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:8080/actuator/health || exit 1

# Run the application
ENTRYPOINT ["java", "-XX:+UseContainerSupport", "-XX:MaxRAMPercentage=75.0", "-jar", "app.jar"]