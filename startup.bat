@echo off
TITLE Jenkins StartUp

SET BASE=%~dp0
SET JENKINS_HOME=%BASE%jenkins_home
SET JAVA_HOME=%BASE%java\jdk-21.0.10.7-hotspot
SET MAVEN_HOME=%BASE%maven\apache-maven-3.0.5

SET PATH=%JAVA_HOME%\bin;%MAVEN_HOME%\bin;%PATH%

SET JENKINS_PORTABLE_HOME=%BASE%

:: Cp1252 is the correct charset name for JDK 17+
:: JAVA_TOOL_OPTIONS is inherited by ALL child processes including Maven
SET JAVA_TOOL_OPTIONS=-Dfile.encoding=Cp1252

SET JAVA_OPTS=-Xms1024m -Xmx2048m -Dfile.encoding=Cp1252 -Djavax.net.ssl.trustStore=NUL -Djavax.net.ssl.trustStoreType=Windows-ROOT

if not exist "%JAVA_HOME%\bin\java.exe" (
    echo ERROR: Java not found at %JAVA_HOME%
    pause
    exit /b 1
)

if not exist "%BASE%jenkins.war" (
    echo ERROR: jenkins.war not found at %BASE%
    pause
    exit /b 1
)

echo ==========================================
echo  Jenkins Portable
echo  URL  : http://localhost:8082
echo  Home : %JENKINS_HOME%
echo  Java : %JAVA_HOME%
echo  Maven: %MAVEN_HOME%
echo ==========================================

"%JAVA_HOME%\bin\java.exe" %JAVA_OPTS% ^
  -DJENKINS_HOME=%JENKINS_HOME% ^
  -DJENKINS_PORTABLE_HOME=%BASE% ^
  -jar "%BASE%jenkins.war" ^
  --httpPort=8082

pause