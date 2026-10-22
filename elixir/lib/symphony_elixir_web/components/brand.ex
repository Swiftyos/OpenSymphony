defmodule SymphonyElixirWeb.Brand do
  @moduledoc """
  Agent Factory branding: the favicon links and the crane logo.

  The logo is the design package's CSS-only animation (agent-factory-raw.tar.gz):
  a crane lowers the n8n cross into place and the n8n snap plays once. Its
  keyframes live in `priv/static/agent_factory_logo.css`; the root layout
  marks the page `afl-played` after the first play in a tab, so later page
  loads show the finished mark.
  """

  use Phoenix.Component

  alias SymphonyElixirWeb.StaticAssets

  @doc "The favicon set and the apple touch icon, for a page's head."
  @spec favicons(map()) :: Phoenix.LiveView.Rendered.t()
  def favicons(assigns) do
    ~H"""
    <link rel="icon" href={StaticAssets.url("/favicon.ico")} sizes="any" />
    <link rel="icon" href={StaticAssets.url("/favicon.svg")} type="image/svg+xml" />
    <link rel="icon" href={StaticAssets.url("/favicon-32.png")} type="image/png" sizes="32x32" />
    <link rel="icon" href={StaticAssets.url("/favicon-16.png")} type="image/png" sizes="16x16" />
    <link rel="apple-touch-icon" href={StaticAssets.url("/apple-touch-icon.png")} />
    """
  end

  attr(:id, :string, required: true, doc: "needed by phx-update=ignore, so LiveView never re-renders it mid-play")
  attr(:class, :any, default: nil)
  attr(:static, :boolean, default: false, doc: "show the finished mark without playing")

  @doc "The crane logo."
  @spec logo(map()) :: Phoenix.LiveView.Rendered.t()
  def logo(assigns) do
    ~H"""
    <span
      id={@id}
      class={["afl", @static && "is-static", @class]}
      role="img"
      aria-label="n8n Agent Factory"
      phx-update="ignore"
    >
        <svg class="afl-svg" viewBox="-2 -46 156 96" aria-hidden="true">
          <defs>
            <%!-- hides the cable above the jib's bottom chord --%>
            <clipPath id="afl-clip"><rect x="-10" y="-27" width="180" height="200"/></clipPath>
          </defs>

          <%!-- Crane (yellow): hook + cable, then lattice mast, jib, peak, cab, counterweight --%>
          <g class="afl-crane">
            <g clip-path="url(#afl-clip)">
              <g class="afl-hook">
                <rect x="58.75" y="-90" width="2.5" height="84" fill="currentColor"/>
                <path d="M55 -8.5Q55 -10 56.5 -10H63.5Q65 -10 65 -8.5L64 -2Q63.7 -0.4 62.2 -0.4H57.8Q56.3 -0.4 56 -2Z" fill="currentColor"/>
              </g>
            </g>
            <path d="M129 -27.00L139 -14.83M139 -27.00L129 -14.83M129 -14.83L139 -2.67M139 -14.83L129 -2.67M129 -2.67L139 9.50M139 -2.67L129 9.50M129 9.50L139 21.67M139 9.50L129 21.67M129 21.67L139 33.83M139 21.67L129 33.83M129 33.83L139 46.00M139 33.83L129 46.00" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/>
            <path d="M129 -27V46M139 -27V46" fill="none" stroke="currentColor" stroke-width="2.75" stroke-linecap="round" stroke-linejoin="round"/>
            <rect x="124" y="44.5" width="20" height="3.5" rx="1.75" fill="currentColor"/>
            <path d="M36.00 -27L44.29 -33M44.29 -33L52.57 -27M52.57 -27L60.86 -33M60.86 -33L69.14 -27M69.14 -27L77.43 -33M77.43 -33L85.71 -27M85.71 -27L94.00 -33M94.00 -33L102.29 -27M102.29 -27L110.57 -33M110.57 -33L118.86 -27M118.86 -27L127.14 -33M127.14 -33L135.43 -27M135.43 -27L143.71 -33M143.71 -33L152.00 -27" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/>
            <path d="M36 -33H152M36 -27H152M36 -33V-27M152 -33V-27" fill="none" stroke="currentColor" stroke-width="2.75" stroke-linecap="round" stroke-linejoin="round"/>
            <path d="M129 -33L134 -44L139 -33M130.5 -38H137.5" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/>
            <path d="M134 -44L66 -33M134 -44L150 -33" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/>
            <rect x="118" y="-26" width="9" height="8" rx="2" fill="currentColor"/>
            <rect x="141" y="-26" width="11" height="9" rx="2" fill="currentColor"/>
          </g>

          <%!-- n8n mark split in three: left + right stay put, the middle cross hangs on the hook --%>
          <g class="afl-pieces">
            <path d="M24 48C26.25 48 27 47.25 27 45V39C27 30 30 27 39 27C41.25 27 42 26.25 42 24C42 21.75 41.25 21 39 21C30 21 27 18 27 9V3C27 0.75 26.25 0 24 0C21.75 0 21 0.75 21 3V9C21 18 18 21 9 21H3C0.75 21 0 21.75 0 24C0 26.25 0.75 27 3 27H9C18 27 21 30 21 39V45C21 47.25 21.75 48 24 48Z"/>
            <path d="M96 48C93.75 48 93 47.25 93 45V39C93 30 90 27 81 27C78.75 27 78 26.25 78 24C78 21.75 78.75 21 81 21C90 21 93 18 93 9V3C93 0.75 93.75 0 96 0C98.25 0 99 0.75 99 3V9C99 18 102 21 111 21H117C119.25 21 120 21.75 120 24C120 26.25 119.25 27 117 27H111C102 27 99 30 99 39V45C99 47.25 98.25 48 96 48Z"/>
            <path class="afl-mid" d="M60 0C62.25 0 63 0.75 63 3V9C63 18 66 21 75 21C77.25 21 78 21.75 78 24C78 26.25 77.25 27 75 27C66 27 63 30 63 39V45C63 47.25 62.25 48 60 48C57.75 48 57 47.25 57 45V39C57 30 54 27 45 27C42.75 27 42 26.25 42 24C42 21.75 42.75 21 45 21C54 21 57 18 57 9V3C57 0.75 57.75 0 60 0Z"/>
          </g>

          <%!-- the original n8n mark path, shown once the cross is seated (no seam) --%>
          <path class="afl-full" d="M24 48C26.25 48 27 47.25 27 45V39C27 30 30 27 39 27H45C54 27 57 30 57 39V45C57 47.25 57.75 48 60 48C62.25 48 63 47.25 63 45V39C63 30 66 27 75 27H81C90 27 93 30 93 39V45C93 47.25 93.75 48 96 48C98.25 48 99 47.25 99 45V39C99 30 102 27 111 27H117C119.25 27 120 26.25 120 24C120 21.75 119.25 21 117 21H111C102 21 99 18 99 9V3C99 0.75 98.25 0 96 0C93.75 0 93 0.75 93 3V9C93 18 90 21 81 21H75C66 21 63 18 63 9V3C63 0.75 62.25 0 60 0C57.75 0 57 0.75 57 3V9C57 18 54 21 45 21H39C30 21 27 18 27 9V3C27 0.75 26.25 0 24 0C21.75 0 21 0.75 21 3V9C21 18 18 21 9 21H3C0.75 21 0 21.75 0 24C0 26.25 0.75 27 3 27H9C18 27 21 30 21 39V45C21 47.25 21.75 48 24 48Z"/>

          <%!-- n8n snap, traced from n8n.io's Lottie (64 frames, 30 fps), shown only while it plays --%>
          <path class="afl-snap" transform="matrix(0.101695 0 0 0.101695 -0.12203 -0.41695)" d="M227.8 473.9C221.2 473.0 218.7 471.8 214.7 468.1C208.6 462.5 208.7 463.1 207.9 408.5C207.2 354.9 206.5 346.9 201.4 329.2C198.2 317.9 195.0 311.2 189.5 303.5C180.5 290.8 168.7 282.5 152.3 277.1C133.8 271.0 130.2 270.7 74.0 270.0C29.6 269.5 21.8 269.2 17.5 267.7C6.9 264.2 3.0 256.7 3.0 240.0C3.0 223.4 6.7 216.3 17.5 212.4C22.0 210.7 27.7 210.5 74.0 209.9C130.2 209.3 133.8 208.9 152.3 202.9C165.5 198.6 173.3 193.9 182.5 184.6C191.8 175.3 197.3 165.4 201.4 150.5C206.5 132.2 207.2 124.1 207.9 71.5C208.5 24.6 208.6 22.3 210.6 18.0C214.9 8.7 221.6 5.6 237.5 5.6C257.4 5.6 264.0 10.8 266.0 28.3C266.6 32.8 267.0 54.0 267.0 75.3C267.0 115.4 267.7 126.8 271.2 143.0C279.6 182.6 302.3 202.2 347.0 208.5C362.8 210.7 464.5 210.7 479.9 208.5C495.2 206.3 505.2 203.4 516.7 197.9C539.3 187.1 552.1 167.6 557.4 136.0C560.0 120.4 561.0 100.5 561.0 61.9C561.0 20.7 561.4 17.6 567.5 11.7C573.2 6.2 586.1 3.8 598.6 5.9C608.0 7.6 613.2 10.8 616.2 16.7C618.5 21.5 618.5 21.8 619.1 69.5C619.5 96.6 620.3 121.2 620.9 126.0C625.0 155.3 631.6 171.7 645.1 185.2C651.5 191.6 654.4 193.6 663.1 197.8C674.3 203.2 688.6 207.2 703.0 209.0C707.8 209.6 735.6 210.0 768.2 210.0C829.6 210.0 838.1 209.5 855.8 204.4C873.5 199.4 888.2 190.0 897.1 178.0C902.3 171.0 905.1 165.5 908.3 155.5C914.9 135.5 916.0 123.3 916.0 73.5C916.0 50.1 916.5 29.8 917.0 26.1C919.6 10.5 926.4 5.6 945.5 5.6C961.4 5.6 968.1 8.7 972.4 18.0C974.4 22.3 974.5 24.6 975.1 71.5C975.7 124.1 976.4 132.7 981.6 150.8C985.6 165.3 991.3 175.3 1000.5 184.6C1009.7 193.9 1017.3 198.5 1030.7 202.9C1049.7 209.1 1060.0 210.1 1116.0 210.9C1169.0 211.7 1168.5 211.6 1174.3 217.8C1178.3 222.0 1180.0 228.7 1180.0 240.1C1180.0 251.7 1178.2 258.0 1173.7 262.8C1168.1 268.6 1165.0 269.0 1123.6 269.0C1069.4 269.0 1049.6 270.8 1030.5 277.1C1017.6 281.4 1009.6 286.2 1000.9 294.9C988.6 307.2 982.3 321.2 977.8 345.9C975.9 356.3 975.7 362.7 975.1 407.5C974.5 452.4 974.3 457.9 972.7 461.5C969.0 469.6 964.7 472.5 953.5 474.1C939.7 476.0 925.7 472.6 921.2 466.3C917.0 460.3 916.7 457.4 916.0 405.0C915.3 351.9 914.9 347.5 909.9 329.0C900.9 295.7 877.2 277.3 836.0 271.5C827.1 270.3 813.9 270.0 768.2 270.0C735.6 270.0 707.8 270.4 703.0 271.0C688.6 272.8 674.3 276.8 663.1 282.2C654.2 286.5 651.5 288.4 644.8 295.1C638.3 301.7 636.2 304.7 632.1 313.3C621.6 335.2 620.0 347.0 619.2 409.5C618.5 456.8 618.4 458.7 616.3 463.1C612.2 472.1 598.8 476.3 582.3 474.0C572.1 472.6 566.5 469.4 563.7 463.1C561.6 458.7 561.5 456.7 560.9 410.5C560.2 364.1 559.6 353.8 556.4 338.4C548.1 297.9 525.3 278.0 479.9 271.5C464.5 269.3 362.8 269.3 347.0 271.5C327.0 274.3 310.4 280.3 299.0 288.8C287.2 297.7 277.5 312.7 273.0 329.1C268.0 347.5 267.8 350.9 267.0 404.5C266.5 438.0 265.9 456.7 265.2 459.0C262.1 468.4 256.9 472.3 245.3 474.0C237.6 475.1 235.8 475.1 227.8 473.9Z"/>
        </svg>
    </span>
    """
  end
end
