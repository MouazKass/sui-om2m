package org.eclipse.om2m.sui;

import java.util.Hashtable;

import org.eclipse.om2m.interworking.service.InterworkingService;
import org.eclipse.om2m.sui.config.SuiConfig;
import org.eclipse.om2m.sui.das.SuiDasService;
import org.eclipse.om2m.sui.failover.FailoverManager;
import org.eclipse.om2m.sui.ptb.PtbBuilder;
import org.eclipse.om2m.sui.sdk.SuiCli;
import org.osgi.framework.BundleActivator;
import org.osgi.framework.BundleContext;
import org.osgi.framework.ServiceRegistration;
import org.apache.commons.logging.Log;
import org.apache.commons.logging.LogFactory;

/**
 * OSGi activator. Wires SuiConfig -> SuiCli -> PtbBuilder ->
 * SuiDasService, then registers the DAS as an OM2M InterworkingService
 * so the CSE's DynamicAuthorizationSelector can route NOTIFYs to it.
 *
 * <p>The integration is conformant to the oneM2M TS-0003
 * dynamic-authorization interface: no OM2M core modification is
 * required. FailoverManager is also brought up at start.
 */
public final class SuiPluginActivator implements BundleActivator {

    private static final Log LOG = LogFactory.getLog(SuiPluginActivator.class);

    private FailoverManager failover;
    private ServiceRegistration<InterworkingService> dasReg;

    @Override
    public void start(BundleContext ctx) {
        LOG.info("[sui] Starting Sui Access Control plugin (DAS mode)");

        SuiConfig cfg = SuiConfig.load();
        SuiCli cli = new SuiCli(cfg.suiCliPath, cfg.suiEnv);
        PtbBuilder ptb = new PtbBuilder(cfg, cli);

        SuiDasService das = new SuiDasService(cfg, ptb);
        dasReg = ctx.registerService(
            InterworkingService.class, das, new Hashtable<>());
        LOG.info("[sui] DAS registered at APOC path: " + das.getAPOCPath());

        failover = new FailoverManager(cfg, cli);
        failover.start();

        LOG.info("[sui] Plugin ready. nodeAddress=" + cfg.nodeAddress + " env=" + cfg.suiEnv);
    }

    @Override
    public void stop(BundleContext ctx) {
        LOG.info("[sui] Stopping Sui Access Control plugin");
        if (dasReg != null) dasReg.unregister();
        if (failover != null) failover.stop();
    }
}
