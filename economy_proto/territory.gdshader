shader_type canvas_item;
// Empire territory, computed per pixel on the GPU: each pixel belongs to the empire whose nearest claimed star system is
// closest, if that system is within `radius`. Borders are drawn where another empire is almost as close (a line between
// empires) or where territory ends. `systems` is a 1-row float texture, one texel per claimed system: (x, y, empire id, 1),
// in the same coordinates as the map.

uniform sampler2D systems : filter_nearest;
uniform int count = 0;
uniform float radius = 70.0;
uniform float border_px = 2.0;
uniform float fill_alpha = 0.13;
uniform float border_alpha = 0.75;
uniform vec4 colors[8];

varying vec2 map_pos;

void vertex() {
	map_pos = VERTEX;   // the rect sits at the map origin, so local coordinates are map coordinates
}

void fragment() {
	float near[8];
	for (int e = 0; e < 8; e++) near[e] = 1e9;
	for (int i = 0; i < count; i++) {
		vec4 s = texelFetch(systems, ivec2(i, 0), 0);
		int e = int(s.z + 0.5) % 8;
		near[e] = min(near[e], distance(map_pos, s.xy));
	}
	int owner = -1;
	float best = 1e9;
	for (int e = 0; e < 8; e++) {
		if (near[e] < best) { best = near[e]; owner = e; }
	}
	float second = 1e9;
	for (int e = 0; e < 8; e++) {
		if (e != owner) second = min(second, near[e]);
	}
	if (owner < 0 || best > radius) {
		COLOR = vec4(0.0);
	} else {
		bool edge_between = (second - best) < border_px * 2.0;   // another empire's territory starts here
		bool edge_out = best > radius - border_px;               // unclaimed space starts here
		COLOR = vec4(colors[owner].rgb, (edge_between || edge_out) ? border_alpha : fill_alpha);
	}
}
