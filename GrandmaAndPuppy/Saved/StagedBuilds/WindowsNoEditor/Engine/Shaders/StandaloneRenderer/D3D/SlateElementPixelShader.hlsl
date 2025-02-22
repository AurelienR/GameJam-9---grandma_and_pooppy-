// Copyright 1998-2015 Epic Games, Inc. All Rights Reserved.


// Shader types
#define ESlateShader::Default		0
#define ESlateShader::Border		1
#define ESlateShader::Font			2
#define ESlateShader::LineSegment	3

// Draw effects
#define DE_Disabled 0x01
#define DE_IgnoreTextureAlpha 0x04

Texture2D ElementTexture;
SamplerState ElementTextureSampler;

cbuffer PerElementPSConstants
{
	float4 ShaderParams;
	uint DrawEffects;
	uint ShaderType;
	uint Padding[2];
};


struct VertexOut
{
	float4 Position : SV_POSITION;
	float4 Color : COLOR0;
	float4 TextureCoordinates : TEXCOORD0;
	float4 ClipOriginAndPos : TEXCOORD1;
	float4 ClipExtents : TEXCOORD2;
};

float3 Hue( float H )
{
    float R = abs(H * 6 - 3) - 1;
    float G = 2 - abs(H * 6 - 2);
    float B = 2 - abs(H * 6 - 4);
    return saturate( float3(R,G,B) );
}

float4 GetFontElementColor( VertexOut InVertex )
{
	float4 OutColor = InVertex.Color;

	OutColor.a *= ElementTexture.Sample(ElementTextureSampler, InVertex.TextureCoordinates.xy).a;
	
	return OutColor;
}

float4 GetColor( VertexOut InVertex, float2 UV )
{
	float4 FinalColor;
	
	float4 BaseColor = ElementTexture.Sample(ElementTextureSampler, UV );
    if( ( DrawEffects & DE_IgnoreTextureAlpha ) != 0 )
    {
        BaseColor.a = 1.0f;
    }

	FinalColor = BaseColor*InVertex.Color;
	return FinalColor;

}

float4 GetDefaultElementColor( VertexOut InVertex )
{
	return GetColor( InVertex, InVertex.TextureCoordinates.xy*InVertex.TextureCoordinates.zw );
}

float4 GetBorderElementColor( VertexOut InVertex )
{
	float2 NewUV;
	if( InVertex.TextureCoordinates.z == 0.0f && InVertex.TextureCoordinates.w == 0.0f )
	{
		NewUV = InVertex.TextureCoordinates.xy;
	}
	else
	{
		float2 MinUV;
		float2 MaxUV;
	
		if( InVertex.TextureCoordinates.z > 0 )
		{
			MinUV = float2(ShaderParams.x,0);
			MaxUV = float2(ShaderParams.y,1);
			InVertex.TextureCoordinates.w = 1.0f;
		}
		else
		{
			MinUV = float2(0,ShaderParams.z);
			MaxUV = float2(1,ShaderParams.w);
			InVertex.TextureCoordinates.z = 1.0f;
		}

		NewUV = InVertex.TextureCoordinates.xy*InVertex.TextureCoordinates.zw;
		NewUV = frac(NewUV);
		NewUV = lerp(MinUV,MaxUV,NewUV);	
	}

	return GetColor( InVertex, NewUV );
}

float4 GetSplineElementColor( VertexOut InVertex )
{
	float Width = ShaderParams.x;
	float Radius = ShaderParams.y;

	float2 StartPos = InVertex.TextureCoordinates.xy;
	float2 EndPos = InVertex.TextureCoordinates.zw;

	float2 Diff = float2( StartPos.y - EndPos.y, EndPos.x - StartPos.x ) ;

	float K = 2/( (2*Radius + Width)*sqrt( dot( Diff, Diff) ) );

	float3 E0 = K*float3( Diff.x, Diff.y, (StartPos.x*EndPos.y - EndPos.x*StartPos.y) );
	E0.z += 1;

	float3 E1 = K*float3( -Diff.x, -Diff.y, (EndPos.x*StartPos.y - StartPos.x*EndPos.y) );
	E1.z += 1;

	float3 Pos = float3(InVertex.Position.xy,1);

	float2 Distance = float2( dot(E0,Pos), dot(E1,Pos) );

	if( any( Distance < 0 ) )
	{
		// using discard instead of clip because
		// apparently clipped pixels are written into the stencil buffer but discards are not
		discard;
	}
	

	float4 Color = InVertex.Color;
	
	float Index = min(Distance.x,Distance.y);

	// Without this, the texture sample sometimes samples the next entry in the table.  Usually occurs when sampling the last entry in the table but instead	
	// samples the first and we get white pixels 
	const float HalfPixelOffset = 1/32.f;

	Color.a *= smoothstep(0.3, 1.0f, Index);

	if( Color.a < 0.05f )
	{
		discard;
	}

	return Color;
}

float cross(float2 a, float2 b)
{
	return a.x*b.y - a.y*b.x;
}

/**
 * Given a point p and a parallelogram defined by point a and vectors b and c, determines in p is inside the parallelogram. 
 * returns a 4-vector that can be used with the clip instruction.
 */
float4 PointInParallelogram(float2 p, float2 a, float4 bc)
{
	// unoptomized form:
	//float2 o = p - a;
	//float2 b = bc.xy;
	//float2 c = bc.zw;
	//float d = cross(b, c);
	//float s = -cross(o, b) / d;
	//float t = cross(o, c) / d;
	// test for s and t between 0 and 1
	//return float4(s, 1 - s, t, 1 - t);

	float2 o = p - a;
	// precompute 1/d
	float invD = 1/cross(bc.xy, bc.zw);
	// Compute an optimized o x b and o x c, leveraging that b and c are in the same vector register already (and free swizzles):
	//   (o.x * b .y  - o.y * b .x, o.x *  c.y - o.y *  c.x) ==
	//   (o.x * bc.y  - o.y * bc.x, o.x * bc.w - o.y * bc.z) ==
	//    o.x * bc.yw - o.y * bc.xz
	float2 st = (o.x * bc.yw - o.y * bc.xz) * float2(-invD, invD);
	// test for s and t between 0 and 1
	return float4(st, float2(1,1) - st);
}

float4 Main( VertexOut InVertex ) : SV_Target
{
	// Clip pixels which are outside of the clipping rect
	float2 ClipOrigin = InVertex.ClipOriginAndPos.xy;
	float2 WindowPos = InVertex.ClipOriginAndPos.zw;
	float4 ClipTest = PointInParallelogram(WindowPos, ClipOrigin, InVertex.ClipExtents);
	
	clip(ClipTest);
	//float4 OutColorTint = any(ClipTest < 0) ? float4(1, 0.5, 0.5, 0.5) : float4(1, 1, 1, 1);

	float4 OutColor;

	if( ShaderType == ESlateShader::Default )
	{
		OutColor = GetDefaultElementColor( InVertex );
	}
	else if( ShaderType == ESlateShader::Border )
	{
		OutColor = GetBorderElementColor( InVertex );
	}
	else if( ShaderType == ESlateShader::Font )
	{
		OutColor = GetFontElementColor( InVertex );
	}
	else
	{
		OutColor = GetSplineElementColor( InVertex );
	}

	// gamma correct
	OutColor.rgb = pow(OutColor.rgb,1.0f/2.2f);

	if( DrawEffects & DE_Disabled )
	{
		//desaturate
		float3 LumCoeffs = float3( 0.3, 0.59, .11 );
		float Lum = dot( LumCoeffs, OutColor.rgb );
		OutColor.rgb = lerp( OutColor.rgb, float3(Lum,Lum,Lum), .8 );
	
		float3 Grayish = {.4, .4, .4};
		
		// lerp between desaturated color and gray color based on distance from the desaturated color to the gray
		OutColor.rgb = lerp( OutColor.rgb, Grayish, clamp( distance( OutColor.rgb, Grayish ), 0, .8)  );
	}

	return OutColor
		//* OutColorTint
		;
}

