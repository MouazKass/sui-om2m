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

public final class SuiPluginActivator implements BundleActivator {
    private static final Log LOG = LogFactory.getLog(SuiPluginActivator.class);
    private FailoverManager failover;
    private ServiceRegistration<InterworkingService> dasReg;

    @Override
    public void start(BundleContext ctx) {
        LOG.info("[sui] Starting Sui Access Control plugin (DAS mode)");
        try {
            LOG.info("[sui-debug] step 1: about to call SuiConfig.load()");
            SuiConfig cfg = SuiConfig.load();
            LOG.info("[sui-debug] step 2: SuiConfig.load() returned");
            SuiCli cli = new SuiCli(cfg.suiCliPath, cfg.suiEnv);
            LOG.info("[sui-debug] step 3: SuiCli created");
            PtbBuilder ptb = new PtbBuilder(cfg, cli);
            LOG.info("[sui-debug] step 4: PtbBuilder created");
            SuiDasService das = new SuiDasService(cfg, ptb);
            LOG.info("[sui-debug] step 5: SuiDasService created");
            dasReg = ctx.registerService(InterworkingService.class, das, new Hashtable<>());
            LOG.info("[sui] DAS registered at APOC path: " + das.getAPOCPath());
            LOG.info("[sui-debug] step 6: about to create FailoverManager");
            failover = new FailoverManager(cfg, cli);
            LOG.info("[sui-debug] step 7: FailoverManager created, about to call start()");
            failover.start();
            LOG.info("[sui-debug] step 8: failover.start() returned");
            LOG.info("[sui] Plugin ready. nodeAddress=" + cfg.nodeAddress + " env=" + cfg.suiEnv);
        } catch (Throwable t) {
            LOG.error("[sui-debug] EXCEPTION: " + t.getClass().getName() + ": " + t.getMessage(), t);
            throw new RuntimeException("Sui plugin start failed", t);
        }
    }

    @Override
    public void stop(BundleContext ctx) {
        LOG.info("[sui] Stopping Sui Access Control plugin");
        if (dasReg != null) dasReg.unregister();
        if (failover != null) failover.stop();
    }
}
