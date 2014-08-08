#ifndef IMAGE_H
#define IMAGE_H

// assumes 8-bit RGB
class Image {
 public:
  std::vector<unsigned char> pixels;
  int width;
  int height;

public:
  // Return pointer to pixel at x,y
  // E.g. this would be the red component image.pixel(x,y)[0] or green image.pixel(x,y)[1]
  
  Image(int width, int height) : width(width), height(height) {
    pixels.resize(width * height * 3);
  }

  unsigned char *pixel(int x, int y) {
    return &pixels[0] + 3 * (x + y * width);
  }

  // Reads entire frame from in.  Returns true IFF we successfully read the frame.
  // Returns false if EOF or some problem
  bool read(FILE *in) {
    return (1 == fread(&pixels[0], pixels.size(), 1, in));
  }

  Image &operator=(const Image &rhs) {
    width = rhs.width;
    height = rhs.height;
    pixels = rhs.pixels;
    return *this;
  }
};

#endif
