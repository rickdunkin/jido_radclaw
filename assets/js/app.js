// phoenix_html (the data-confirm interceptor) MUST be imported first: both it
// and LiveView install window click listeners, and registering phoenix_html's
// first lets a cancelled confirm stop LiveView's later phx-click handler.
import "phoenix_html";
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";

let csrfToken = document
  .querySelector("meta[name='csrf-token']")
  ?.getAttribute("content");
let liveSocket = new LiveSocket("/live", Socket, {
  params: { _csrf_token: csrfToken },
});

liveSocket.connect();

window.liveSocket = liveSocket;
