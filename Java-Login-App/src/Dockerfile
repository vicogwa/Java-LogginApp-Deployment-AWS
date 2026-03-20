# Use official Tomcat 9 wiyth JDK 17
FROM tomcat:9-jdk17

# Set environment variables (optional, useful for scripts/logging)
ENV CATALINA_HOME /usr/local/tomcat
ENV JAVA_OPTS="-Djava.security.egd=file:/dev/./urandom"

# Remove default Tomcat webapps to keep container clean
RUN rm -rf $CATALINA_HOME/webapps/*

# Copy your built WAR file into Tomcat as ROOT.war
COPY target/dptweb-1.0.war $CATALINA_HOME/webapps/ROOT.war

# Expose Tomcat default port
EXPOSE 8080

# Use catalina.sh to start Tomcat in foreground
CMD ["catalina.sh", "run"]
