// Stand-ins for the CityLimits game code the reusable interface files call, so
// check-citylimits.sh can build them on their own. Written for this check, not from CityLimits.

namespace CityLimits.Stubs;

public static class Hud
{
    public static int BarTop() => Raylib.GetScreenHeight() - 40;
}

public static class LoadingPhrases
{
    public static string[] All => ["Reticulating splines"];
}

public enum TileKind { Dirt, Water, Trees, Rubble }

public enum TileUse
{
    None, Road, RoadAcrossPowerLine, RoadDownPowerLine, PowerLine, Rail, RailAcrossRoad, RailDownRoad,
    RailAcrossPowerLine, RailDownPowerLine, Park, Hospital, Church, FireStation, PoliceStation, Residential,
    Commercial, Industrial, CoalPowerPlant, NuclearPowerPlant, Stadium, Seaport, Airport,
}

public enum NewsKind { Headline, Advisory }

public sealed class NewsItem
{
    public NewsItem(string text, NewsKind kind)
    {
        Text = text;
        Kind = kind;
    }

    public string Text { get; }

    public NewsKind Kind { get; }
}

public sealed class NewsTicker
{
    public const int Height = 24;

    public NewsTicker(Func<NewsItem> filler, int fontSize = 20)
    {
    }

    public void Update(float elapsed, int width, float startShare = 1f)
    {
    }

    public void Draw(int top, int width, bool background = true)
    {
    }
}

public sealed class GameAssets
{
    public Texture2D? Logo { get; private set; }
}
