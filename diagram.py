from diagrams import Diagram, Cluster, Edge
from diagrams.azure.compute import FunctionApps
from diagrams.azure.database import CosmosDb
from diagrams.azure.monitor import Monitor
from diagrams.azure.integration import EventGridTopics

graph_attr = {
    "fontsize": "20",
    "bgcolor": "white",
    "pad": "0.5",
    "splines": "ortho",
}

with Diagram(
    "Azure Website Uptime Monitor",
    filename="docs/architecture",
    outformat="png",
    graph_attr=graph_attr,
    show=False,
):
    with Cluster("Function App\nuptime-monitor (timer 5 min)"):
        fn = FunctionApps("HTTP / SSL /\nContent check\n+ 1 retry")

    cosmos = CosmosDb("Cosmos DB\nserverless · 90-day TTL")

    with Cluster("Azure Monitor"):
        ai = Monitor("App Insights\nstructured logs")
        a_down = Monitor("site-down\nKQL alert")
        a_lat = Monitor("high-latency\nKQL alert")
        a_ssl = Monitor("ssl-expiry\nKQL alert")

    ag = EventGridTopics("Action Group\nemail / SMS")

    fn >> Edge(label="log result") >> cosmos
    fn >> Edge(label="structured logs") >> ai
    ai >> a_down >> ag
    ai >> a_lat >> ag
    ai >> a_ssl >> ag
