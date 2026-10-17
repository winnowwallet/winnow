import com.licel.jcardsim.base.Simulator;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.lang.reflect.Field;
import java.util.HexFormat;
import javacard.framework.AID;
import org.satochip.applet.CardEdge;
import org.satochip.applet.Biginteger;

/** Development-only bridge. Upstream applet sources remain unmodified. */
public final class SimulatorBridge extends Simulator {
    private static final HexFormat HEX = HexFormat.of();

    public static void main(String[] args) throws Exception {
        SimulatorBridge simulator = new SimulatorBridge();
        byte[] bytes = HEX.parseHex("5361746f4368697000");
        AID aid = new AID(bytes, (short) 0, (byte) bytes.length);
        simulator.installApplet(aid, CardEdge.class);
        simulator.selectApplet(aid);
        byte[] x = new byte[32], y = new byte[32], product = new byte[96];
        x[31] = 2;
        y[31] = 3;
        Biginteger.mult_rsa_trick(x, (short) 0, y, (short) 0, (short) 32, product, (short) 0);
        if (!new java.math.BigInteger(1, product).equals(java.math.BigInteger.valueOf(6))) {
            throw new IllegalStateException("simulator RSA multiplication self-check failed");
        }
        BufferedReader input = new BufferedReader(new InputStreamReader(System.in));
        String line;
        while ((line = input.readLine()) != null) {
            if (line.equals("RESET")) {
                simulator.reset();
                simulator.selectApplet(aid);
                System.out.println("9000");
            } else if (line.startsWith("COUNTER ")) {
                // Boundary fault injection, never an APDU or a card capability.
                Field counter = CardEdge.class.getDeclaredField("bip327_counter");
                counter.setAccessible(true);
                counter.setShort(simulator.runtime.lookupApplet(aid).getApplet(),
                                 (short) Integer.parseInt(line.substring(8)));
                System.out.println("9000");
            } else {
                System.out.println(HEX.formatHex(simulator.transmitCommand(HEX.parseHex(line))));
            }
            System.out.flush();
        }
    }
}
