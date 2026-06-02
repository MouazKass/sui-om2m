package org.eclipse.om2m.sui.trust;

import org.apache.commons.logging.Log;
import org.apache.commons.logging.LogFactory;

/**
 * Thin adapter exposing slf4j-style "{}" formatting on top of commons-logging,
 * so the trust classes can keep their parameterised log calls without adding an
 * slf4j dependency to the plugin pom.
 */
final class Slf4jStyleLog {
    private final Log log;
    private Slf4jStyleLog(Class<?> c) { this.log = LogFactory.getLog(c); }
    static Slf4jStyleLog getLogger(Class<?> c) { return new Slf4jStyleLog(c); }

    private static String fmt(String tmpl, Object... args) {
        if (args == null || args.length == 0) return tmpl;
        StringBuilder sb = new StringBuilder();
        int ai = 0, i = 0;
        while (i < tmpl.length()) {
            if (i + 1 < tmpl.length() && tmpl.charAt(i) == '{' && tmpl.charAt(i + 1) == '}') {
                sb.append(ai < args.length ? String.valueOf(args[ai++]) : "{}");
                i += 2;
            } else {
                sb.append(tmpl.charAt(i++));
            }
        }
        return sb.toString();
    }

    void info(String t, Object... a)  { if (log.isInfoEnabled())  log.info(fmt(t, a)); }
    void warn(String t, Object... a)  { if (log.isWarnEnabled())  log.warn(fmt(t, a)); }
    void debug(String t, Object... a) { if (log.isDebugEnabled()) log.debug(fmt(t, a)); }
    void error(String t, Object... a) { if (log.isErrorEnabled()) log.error(fmt(t, a)); }
}
