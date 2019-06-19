Shader "PeerPlay/RaymarchShader"
{
	Properties
	{
		_MainTex ("Texture", 2D) = "white" {}
		_Color("Color", Color) = (1,1,1,1)
		_MainTex2("Albedo (RGB)", 2D) = "white" {}
		_Glossiness("Smoothness", Range(0,1)) = 0.5
		_Metallic("Metallic", Range(0,1)) = 0.0
	}
	SubShader
	{
		// No culling or depth
		Cull Off ZWrite Off ZTest Always

		Pass
		{
			CGPROGRAM
			#pragma vertex vert
			#pragma fragment frag
			#pragma target 3.0
			
			#include "UnityCG.cginc"
			#include "DistanceFunctions.cginc"

			sampler2D _MainTex;
			uniform sampler2D _CameraDepthTexture;
			uniform float4x4 _CamFrustum, _CamToWorld;
			uniform int _MaxIterations;
			uniform float _Accuracy;
			uniform float _maxDistance, _box1round, _boxSphereSmooth, _sphereIntersectSmooth;
			uniform float4 _sphere1, _sphere2, _box1;
			uniform float3 _modInterval;
			uniform float3 _LightDir, _LightCol;
			uniform float _LightIntensity;
			uniform fixed4 _mainColor;
			uniform float2 _ShadowDistance;
			uniform float _ShadowIntensity, _ShadowPenumbra;

			uniform float4 _sphere;
			uniform float _sphereSmooth;
			uniform float _degreeRotate;

			uniform int _ballAmount;


			struct appdata
			{
				float4 vertex : POSITION;
				float2 uv : TEXCOORD0;
			};

			struct v2f
			{
				float2 uv : TEXCOORD0;
				float4 vertex : SV_POSITION;
				float3 ray : TEXCOORD1;
			};

			v2f vert (appdata v)
			{
				v2f o;
				half index = v.vertex.z;
				v.vertex.z = 0;
				o.vertex = UnityObjectToClipPos(v.vertex);
				o.uv = v.uv;

				o.ray = _CamFrustum[(int)index].xyz;

				o.ray /= abs(o.ray.z);

				o.ray = mul(_CamToWorld, o.ray);

				return o;
			}

			//float BoxSphere(float3 p)
			//{
			//	float Sphere1 = sdSphere(p - _sphere1.xyz, _sphere1.w);
			//	float Box1 = sdRoundBox(p - _box1.xyz, _box1.www, _box1round);
			//	float combine1 = opSS(Sphere1, Box1, _boxSphereSmooth);
			//	float Sphere2 = sdSphere(p - _sphere2.xyz, _sphere2.w);
			//	float combine2 = opIS(Sphere2, combine1, _sphereIntersectSmooth);
			//
			//	return combine2;
			//}

			float3 RotateY(float3 v, float degree)
			{
				float rad = 0.0174532925 * degree;
				float cosY = cos(rad);
				float sinY = sin(rad);
				return float3(cosY * v.x - sinY * v.z, v.y, sinY * v.x + cosY * v.z);
			}

			float distanceField(float3 p)
			{
				float ground = sdPlane(p, float4(0, 1, 0, 0));
				float sphere = sdSphere(p - _sphere.xyz, _sphere.w);
				for (int i = 1; i < _ballAmount; i++)
				{
					float sphereAdd = sdSphere(RotateY(p, _degreeRotate * i) - _sphere.xyz, _sphere.w);
					sphere = opUS(sphere, sphereAdd, _sphereSmooth);
				}
				return opU(sphere, ground);
				//float boxSphere1 = BoxSphere(p);
				//
				//return opU(ground, boxSphere1);
			}

			float3 getNormal(float3 p)
			{
				const float2 offset = float2(0.001, 0.0);
				float3 n = float3(
					distanceField(p + offset.xyy) - distanceField(p - offset.xyy),
					distanceField(p + offset.yxy) - distanceField(p - offset.yxy),
					distanceField(p + offset.yyx) - distanceField(p - offset.yyx));
				return normalize(n);
			}

			float hardShadow(float3 ro, float rd, float mint, float maxt)
			{
				for (float t = mint; t < maxt;)
				{
					float h = distanceField(ro + rd * t);
					if (h < 0.001)
					{
						return 0.0;
					}
					t += h;
				}
				return 1.0;
			}
			float softShadow(float3 ro, float rd, float mint, float maxt, float k)
			{
				float result = 1.0;
				for (float t = mint; t < maxt;)
				{
					float h = distanceField(ro + rd * t);
					if (h < 0.001)
					{
						return 0.0;
					}
					result = min(result, k*h / t);
					t += h;
				}
				return result;
			}

			uniform float _AoStepsize, _AoInstensity;
			uniform int _AoIterations;

			float AmbientOcclusion(float3 p, float3 n)
			{
				float step = _AoStepsize;
				float ao = 0.0;
				float dist;
				for (int i = 1; i <= _AoIterations; i++)
				{
					dist = step * i;
					ao += max(0.0, (dist - distanceField(p + n * dist)) / dist);
				}
				return (1.0 - ao * _AoInstensity);
			}
				
			float3 Shading(float3 p, float3 n)
			{
				float3 result;
				//Diffuse Color
				float3 color = _mainColor.rgb;
				//Directional Light
				float3 light = (_LightCol * dot(-_LightDir, n) * 0.5 + 0.5) * _LightIntensity;
				//Shadows
				float shadow = softShadow(p, -_LightDir, _ShadowDistance.x, _ShadowDistance.y, _ShadowPenumbra) * 0.5 + 0.5;
				shadow = max(0.0, pow(shadow, _ShadowIntensity));
				//AMBIENNT OOCCLLUUU
				float ao = AmbientOcclusion(p, n);


				result = color * light * shadow * ao;

				return result;
			}
			
			fixed4 raymarching(float3 ro, float3 rd, float depth)
			{
				fixed4 result = fixed4(1, 1, 1, 1);
				const int max_iteration = _MaxIterations;
				float t = 0; //distance travelled along the ray direction

				for (int i = 0; i < max_iteration; i++)
				{
					if (t > _maxDistance || t >= depth)
					{
						//env
						result = fixed4(rd, 0);
						break;
					}

					float3 p = ro + rd * t;
					//check for hit in distfield
					float d = distanceField(p);

					if (d < _Accuracy)
					{
						//shading!
						float3 n = getNormal(p);
						float3 s = Shading(p, n);

						result = fixed4(s, 1);
						break;
					}
					t += d;
				}

				return result;
			}

			void surf(Input IN, inout SurfaceOutputStandard o) {
				// Albedo comes from a texture tinted by color
				fixed4 c = tex2D(_MainTex2, IN.uv_MainTex) * _Color;
				o.Albedo = c.rgb;
				// Metallic and smoothness come from slider variables
				o.Metallic = _Metallic;
				o.Smoothness = _Glossiness;
				o.Alpha = c.a;
			}

			fixed4 frag (v2f i) : SV_Target
			{
				float depth = LinearEyeDepth(tex2D(_CameraDepthTexture, i.uv).r);
				depth *= length(i.ray);
				fixed3 col = tex2D(_MainTex, i.uv);
				float3 rayDirection = normalize(i.ray.xyz);
				float3 rayOrigin = _WorldSpaceCameraPos;
				fixed4 result = raymarching(rayOrigin, rayDirection, depth);
				return fixed4(col * (1.0 - result.w) + result.xyz * result.w,1.0);
			}
			ENDCG
		}
	}
}
