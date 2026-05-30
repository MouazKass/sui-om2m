package org.eclipse.om2m.sui;

import org.eclipse.om2m.sui.config.SuiConfig;
import org.eclipse.om2m.sui.failover.FailoverManager;
import org.eclipse.om2m.sui.proxy.AccessControlProxy;
import org.eclipse.om2m.sui.ptb.PtbBuilder;
import org.eclipse.om2m.sui.sdk.SuiCli;
import org.osgi.framework.BundleActivator;
import org.osgi.framework.BundleContext;
import org.osgi.framework.ServiceRegistration;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.Hashtable;

/**
 * OSGi activator. Wires SuiConfig -> SuiCli -> PtbBuilder ->
 * AccessControlProxy and FailoverManager, then registers the proxy as
 * an OSGi service so the CSE can look it up and call intercept() on
 * inbound requests.
 *
 * <p>Mirrors the structure of Hammad et al.'s decentralisation plugin:
 * a single Activator that brings up the integration layer at bundle
 * start and tears it down at bundle stop.
 */
public final class SuiPluginActivator implements BundleActivator {

    private static final Logger LOG = LoggerFactory.getLogger(SuiPluginActivator.class);

    private FailoverManager failover;
    private ServiceRegistration<AccessControlProxy> proxyReg;

    @Override
    public void start(BundleContext ctx) {
        LOG.info("[sui] Starting Sui Access Control plugin");
        SuiConfig cfg = SuiConfig.load();
        SuiCli cli = new SuiCli(cfg.suiCliPath, cfg.suiEnv);
        PtbBuilder ptb = new PtbBuilder(cfg, cli);

        AccessControlProxy proxy = new AccessControlProxy(cfg, ptb);
        proxyReg = ctx.registerService(
            AccessControlProxy.class, proxy, new Hashtable<>());

        failover = new FailoverManager(cfg, cli);
        failover.start();

        LOG.info("[sui] Plugin ready. nodeAddress={} env={}", cfg.nodeAddress, cfg.suiEnv);
    }

    @Override
    public void stop(BundleContext ctx) {
        LOG.info("[sui] Stopping Sui Access Control plugin");
        if (proxyReg != null) proxyReg.unregister();
        if (failover != null) failover.stop();
    }
}
