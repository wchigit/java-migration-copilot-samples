# Multi-stage build for Spring Boot worker application
# This Dockerfile should be run from the root directory of the project
# Build stage
FROM maven:3.9.4-eclipse-temurin-21 AS builder

# Set working directory
WORKDIR /app

# Copy parent pom.xml first for better layer caching
COPY pom.xml ./

# Copy module pom files
COPY web/pom.xml ./web/
COPY worker/pom.xml ./worker/

# Download dependencies (better layer caching)
RUN mvn dependency:go-offline -pl worker -am

# Copy source code
COPY worker/src ./worker/src

# Build only the worker module
RUN mvn clean package -DskipTests -pl worker -am

# Runtime stage
FROM eclipse-temurin:21-jre-jammy

# Install curl for health checks
RUN apt-get update && apt-get install -y curl && rm -rf /var/lib/apt/lists/*

# Create non-root user for security
RUN groupadd -r appgroup && useradd -r -g appgroup appuser

# Set working directory
WORKDIR /app

# Copy the built JAR from builder stage
COPY --from=builder /app/worker/target/*.jar app.jar

# Change ownership to non-root user
RUN chown -R appuser:appgroup /app

# Switch to non-root user
USER appuser

# Expose port for health checks
EXPOSE 8080

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:8080/actuator/health || exit 1

# Run the application
ENTRYPOINT ["java", "-jar", "app.jar"]